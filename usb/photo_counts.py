"""Aggregate Photos counts from a bounded, transient in-memory USB snapshot.

Only a fixed Photos.sqlite path and its WAL may be read. No image/video bytes,
filenames, titles, locations or individual asset rows leave this module. The
snapshot is never written to disk or added to an archive. No phone writes.
"""
import asyncio
import sqlite3
import struct

MAX_DATABASE = 32 * 1024 * 1024
MAX_WAL = 16 * 1024 * 1024
DATABASE = '/PhotoData/Photos.sqlite'


def checksum(data, order, initial=(0, 0)):
    if len(data) % 8:
        raise ValueError('invalid_wal_checksum_input')
    a, b = initial
    for x, y in struct.iter_unpack(order + 'II', data):
        a = (a + x + b) & 0xffffffff
        b = (b + y + a) & 0xffffffff
    return a, b


def committed_database(database, wal=b''):
    if not 512 <= len(database) <= MAX_DATABASE or database[:16] != b'SQLite format 3\0':
        raise ValueError('invalid_photo_database')
    page_size = int.from_bytes(database[16:18], 'big')
    if page_size == 1:
        page_size = 65536
    if page_size < 512 or page_size > 65536 or page_size & (page_size - 1) or len(database) % page_size:
        raise ValueError('invalid_photo_database')
    result = bytearray(database)
    if wal:
        if not 32 <= len(wal) <= MAX_WAL:
            raise ValueError('invalid_photo_wal')
        magic, version, wal_page = struct.unpack('>III', wal[:12])
        if magic not in (0x377f0682, 0x377f0683) or version != 3007000 or wal_page != page_size:
            raise ValueError('invalid_photo_wal')
        order = '<' if magic == 0x377f0682 else '>'
        rolling = checksum(wal[:24], order)
        if rolling != struct.unpack('>II', wal[24:32]):
            raise ValueError('invalid_photo_wal')
        pending = {}
        for offset in range(32, len(wal), 24 + page_size):
            frame = wal[offset:offset + 24 + page_size]
            # SQLite may retain old frames past the final current transaction.
            if len(frame) != 24 + page_size:
                raise ValueError('incomplete_photo_wal')
            if frame[8:16] != wal[16:24]:
                break
            page, commit_size = struct.unpack('>II', frame[:8])
            if page == 0 or page * page_size > MAX_DATABASE or commit_size * page_size > MAX_DATABASE:
                raise ValueError('photo_snapshot_limit')
            candidate = checksum(frame[:8] + frame[24:], order, rolling)
            if candidate != struct.unpack('>II', frame[16:24]):
                raise ValueError('invalid_photo_wal')
            rolling = candidate
            pending[page] = frame[24:]
            if commit_size:
                size = commit_size * page_size
                if size > len(result):
                    result.extend(b'\0' * (size - len(result)))
                for number, data in pending.items():
                    if number <= commit_size:
                        result[(number - 1)*page_size:number*page_size] = data
                del result[size:]
                pending.clear()
    # This private in-memory image now contains only committed pages. There is
    # no file-backed WAL reader; change the memory copy to rollback format.
    result[18:20] = b'\x01\x01'
    return bytes(result)


def aggregate_photos(database, wal=b''):
    snapshot = committed_database(database, wal)
    connection = sqlite3.connect(':memory:')
    try:
        connection.deserialize(snapshot)
        connection.execute('PRAGMA trusted_schema=OFF')
        connection.execute('PRAGMA query_only=ON')
        connection.execute('PRAGMA temp_store=MEMORY')
        connection.setlimit(sqlite3.SQLITE_LIMIT_LENGTH, 1024 * 1024)
        connection.setlimit(sqlite3.SQLITE_LIMIT_SQL_LENGTH, 4096)
        budget = 4000
        def progress():
            nonlocal budget
            budget -= 1
            return int(budget <= 0)
        connection.set_progress_handler(progress, 1000)
        for table in ('ZASSET', 'ZGENERICASSET'):
            # Fixed table names only; never execute SQL from the device.
            found = connection.execute('SELECT type FROM sqlite_master WHERE name=?', (table,)).fetchone()
            if found != ('table',):
                continue
            columns = {row[1] for row in connection.execute('PRAGMA table_info("'+table+'")')}
            if not {'ZKIND','ZTRASHEDSTATE','ZHIDDEN','ZVISIBILITYSTATE'} <= columns:
                continue
            row = connection.execute('SELECT COUNT(CASE WHEN ZKIND=0 THEN 1 END), '
                'COUNT(CASE WHEN ZKIND=1 THEN 1 END) FROM "'+table+'" WHERE ZTRASHEDSTATE=0 AND ZHIDDEN=0 AND ZVISIBILITYSTATE=0').fetchone()
            if row is not None and all(type(n) is int and 0 <= n <= 100_000_000 for n in row):
                return {'PhotoCount': row[0], 'VideoCount': row[1]}
        raise ValueError('unsupported_photo_schema')
    finally:
        connection.close()


async def file_state(afc, path, limit, optional=False):
    from pymobiledevice3.exceptions import AfcFileNotFoundError
    try:
        value = await afc.stat(path)
    except AfcFileNotFoundError:
        if optional:
            return None
        raise
    size = value.get('st_size')
    if value.get('st_ifmt') != 'S_IFREG' or type(size) is not int or not 0 <= size <= limit:
        raise ValueError('photo_snapshot_limit')
    return {key:value.get(key) for key in ('st_size','st_mtime','st_birthtime','st_ino')}


async def read_file(afc, path, state):
    if state is None:
        return b''
    handle = await afc.fopen(path, 'r')
    try:
        result = bytearray()
        while len(result) < state['st_size']:
            chunk = await afc.fread(handle, min(1024 * 1024, state['st_size'] - len(result)))
            if not isinstance(chunk, bytes) or not chunk or len(chunk) > state['st_size'] - len(result):
                raise ValueError('short_photo_snapshot')
            result.extend(chunk)
        return bytes(result)
    finally:
        await afc.fclose(handle)


async def read_photo_counts(ld):
    from pymobiledevice3.services.afc import AfcService
    async with AfcService(ld) as afc:
        # Do not follow a substituted/symlinked Photos directory.
        if (await afc.stat('/PhotoData')).get('st_ifmt') != 'S_IFDIR':
            raise ValueError('invalid_photo_directory')
        before = await file_state(afc, DATABASE, MAX_DATABASE)
        wal_before = await file_state(afc, DATABASE+'-wal', MAX_WAL, optional=True)
        database = await read_file(afc, DATABASE, before)
        wal = await read_file(afc, DATABASE+'-wal', wal_before)
        # Read the small header again, plus stat checks, to reject concurrent
        # checkpoints. WAL checksum/commit boundaries reject incomplete writes.
        header_state = {'st_size':100}
        header = await read_file(afc, DATABASE, header_state)
        if database[:100] != header or before != await file_state(afc, DATABASE, MAX_DATABASE) or wal_before != await file_state(afc, DATABASE+'-wal', MAX_WAL, optional=True):
            raise ValueError('photo_snapshot_changed')
    return await asyncio.to_thread(aggregate_photos, database, wal)
