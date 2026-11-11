package appstore

import (
	"archive/zip"
	"crypto/md5"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"howett.net/plist"
	"io"
	"os"
	zippath "path"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
)

// RawPackageCache retains only Apple's unpersonalized encrypted payload.
// Download still requests a new account-specific Apple response before consulting it.
type RawPackageCache struct {
	Root        string
	MaxBytes    int64
	MaxPackages int
}
type rawCacheEntry struct {
	AppID    int64    `json:"app_id"`
	Platform Platform `json:"platform"`
	MD5      string   `json:"md5"`
	SHA256   string   `json:"sha256"`
	Bytes    int64    `json:"bytes"`
}

var rawDigestPattern = regexp.MustCompile(`^[a-fA-F0-9]{32}$`)

func rawKey(id int64, p Platform, digest string) string {
	v := sha256.Sum256([]byte(strings.Join([]string{strconvID(id), string(p), strings.ToLower(digest)}, "\x00")))
	return hex.EncodeToString(v[:])
}
func strconvID(id int64) string { b, _ := json.Marshal(id); return string(b) }
func rawDigests(path string) (int64, string, string, error) {
	f, e := os.Open(path)
	if e != nil {
		return 0, "", "", e
	}
	defer f.Close()
	a, b := md5.New(), sha256.New()
	n, e := io.Copy(io.MultiWriter(a, b), f)
	return n, hex.EncodeToString(a.Sum(nil)), hex.EncodeToString(b.Sum(nil)), e
}
func rawEligible(path string) bool {
	z, e := zip.OpenReader(path)
	if e != nil {
		return false
	}
	defer z.Close()
	found := false
	for _, f := range z.File {
		name := strings.ToLower(f.Name)
		if name == "itunesmetadata.plist" || strings.HasSuffix(name, ".sinf") || strings.HasSuffix(name, ".supp") || strings.HasSuffix(name, ".supf") {
			return false
		}
		if f.FileInfo().IsDir() && f.UncompressedSize64 == 0 {
			continue
		}
		if strings.Contains(name, "/sc_info/") && !strings.HasSuffix(name, "/manifest.plist") {
			return false
		}
		if strings.HasSuffix(name, "/sc_info/manifest.plist") {
			if f.UncompressedSize64 > 65536 {
				return false
			}
			r, err := f.Open()
			if err != nil {
				return false
			}
			b, err := io.ReadAll(io.LimitReader(r, 65537))
			r.Close()
			var m map[string]any
			if err != nil || len(b) > 65536 {
				return false
			}
			if _, err = plist.Unmarshal(b, &m); err != nil || !rawManifestEligible(m) {
				return false
			}
		}
		if isTopLevelAppInfoPlist(f.Name) {
			found = true
		}
	}
	return found
}

// Both fields describe relative SINF filenames, never license contents.
// Unknown fields remain rejected so account material cannot enter a shared cache.
func rawManifestEligible(m map[string]any) bool {
	if len(m) < 1 || len(m) > 2 {
		return false
	}
	if _, ok := m["SinfPaths"]; !ok {
		return false
	}
	for key, value := range m {
		if key != "SinfPaths" && key != "SinfReplicationPaths" {
			return false
		}
		paths, ok := value.([]any)
		if !ok || len(paths) > 64 {
			return false
		}
		for _, v := range paths {
			s, ok := v.(string)
			if !ok || len(s) > 512 || strings.ContainsAny(s, "\\\x00\r\n") || zippath.IsAbs(s) || zippath.Clean(s) != s || strings.HasPrefix(s, "../") || !strings.HasSuffix(strings.ToLower(s), ".sinf") {
				return false
			}
		}
	}
	return true
}

func (c *RawPackageCache) Load(id int64, p Platform, digest, dest string) bool {
	if c == nil || c.Root == "" || !rawDigestPattern.MatchString(digest) {
		return false
	}
	if state, e := os.Lstat(c.Root); e != nil || !state.IsDir() || state.Mode()&os.ModeSymlink != 0 {
		return false
	}
	key := rawKey(id, p, digest)
	path := filepath.Join(c.Root, key+".rawipa")
	index := filepath.Join(c.Root, key+".json")
	if s, e := os.Lstat(path); e != nil || !s.Mode().IsRegular() {
		return false
	}
	if state, e := os.Lstat(index); e != nil || !state.Mode().IsRegular() {
		return false
	}
	b, e := os.ReadFile(index)
	if e != nil || len(b) > 4096 {
		return false
	}
	var meta rawCacheEntry
	if json.Unmarshal(b, &meta) != nil || meta.AppID != id || meta.Platform != p || !strings.EqualFold(meta.MD5, digest) {
		return false
	}
	size, md, sha, e := rawDigests(path)
	if e != nil || size != meta.Bytes || md != strings.ToLower(digest) || sha != meta.SHA256 || !rawEligible(path) {
		return false
	}
	in, e := os.Open(path)
	if e != nil {
		return false
	}
	defer in.Close()
	out, e := os.OpenFile(dest, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if e != nil {
		return false
	}
	n, e := io.Copy(out, in)
	closeErr := out.Close()
	if e != nil || closeErr != nil || n != size {
		_ = os.Remove(dest)
		return false
	}
	copied, md2, sha2, e := rawDigests(dest)
	if e != nil || copied != size || md2 != md || sha2 != sha {
		_ = os.Remove(dest)
		return false
	}
	return true
}
func (c *RawPackageCache) Store(id int64, p Platform, digest, source string) bool {
	if c == nil || c.Root == "" || !rawDigestPattern.MatchString(digest) || !rawEligible(source) {
		return false
	}
	if os.MkdirAll(c.Root, 0700) != nil {
		return false
	}
	if s, e := os.Lstat(c.Root); e != nil || !s.IsDir() || s.Mode()&os.ModeSymlink != 0 {
		return false
	}
	lock, e := os.OpenFile(filepath.Join(c.Root, ".lock"), os.O_CREATE|os.O_RDWR, 0600)
	if e != nil {
		return false
	}
	defer lock.Close()
	if syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB) != nil {
		return false
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	key := rawKey(id, p, digest)
	target := filepath.Join(c.Root, key+".rawipa")
	if _, e = os.Lstat(target); e == nil {
		return false
	}
	size, md, sha, e := rawDigests(source)
	if e != nil || size == 0 || md != strings.ToLower(digest) {
		return false
	}
	var total int64
	count := 0
	files, e := os.ReadDir(c.Root)
	if e != nil {
		return false
	}
	for _, f := range files {
		if strings.HasSuffix(f.Name(), ".rawipa") {
			s, e := f.Info()
			if e != nil {
				return false
			}
			total += s.Size()
			count++
		}
	}
	maxBytes := c.MaxBytes
	if maxBytes == 0 {
		maxBytes = 4 << 30
	}
	maxCount := c.MaxPackages
	if maxCount == 0 {
		maxCount = 16
	}
	if count >= maxCount || size > maxBytes-total {
		return false
	}
	tmp, e := os.CreateTemp(c.Root, ".incoming-")
	if e != nil {
		return false
	}
	name := tmp.Name()
	defer os.Remove(name)
	in, e := os.Open(source)
	if e != nil {
		tmp.Close()
		return false
	}
	n, e := io.Copy(tmp, in)
	in.Close()
	if e == nil {
		e = tmp.Sync()
	}
	closeErr := tmp.Close()
	if e != nil || closeErr != nil || n != size {
		return false
	}
	copied, md2, sha2, e := rawDigests(name)
	if e != nil || copied != size || md2 != md || sha2 != sha {
		return false
	}
	if os.Rename(name, target) != nil {
		return false
	}
	meta := rawCacheEntry{AppID: id, Platform: p, MD5: md, SHA256: sha, Bytes: size}
	b, e := json.Marshal(meta)
	if e != nil {
		return false
	}
	file, e := os.CreateTemp(c.Root, ".index-")
	if e != nil {
		return false
	}
	indexName := file.Name()
	defer os.Remove(indexName)
	_, e = file.Write(b)
	closeErr = file.Close()
	if e != nil || closeErr != nil {
		return false
	}
	return os.Rename(indexName, filepath.Join(c.Root, key+".json")) == nil
}
