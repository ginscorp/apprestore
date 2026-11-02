package main

import (
	"archive/zip"
	"crypto/sha256"
	"errors"
	"howett.net/plist"
	"io"
	"strings"
)

// Validate the contract independently of the downloader: identity, main executable,
// and Apple-issued FairPlay license must all be present before exposing the IPA.
func packageState(path string, appID int64, requireLicense bool) ([32]byte, error) {
	var zero [32]byte
	z, err := zip.OpenReader(path)
	if err != nil {
		return zero, err
	}
	defer z.Close()
	var infoFile, metadata *zip.File
	for _, f := range z.File {
		parts := strings.Split(f.Name, "/")
		if len(parts) == 3 && parts[0] == "Payload" && strings.HasSuffix(parts[1], ".app") && parts[2] == "Info.plist" {
			if infoFile != nil {
				return zero, errors.New("multiple_apps")
			}
			infoFile = f
		}
		if f.Name == "iTunesMetadata.plist" {
			metadata = f
		}
	}
	if infoFile == nil || metadata == nil {
		return zero, errors.New("package_metadata_missing")
	}
	readPlist := func(f *zip.File, target any) error {
		if f.UncompressedSize64 > 4*1024*1024 {
			return errors.New("metadata_too_large")
		}
		r, e := f.Open()
		if e != nil {
			return e
		}
		defer r.Close()
		b, e := io.ReadAll(io.LimitReader(r, 4*1024*1024+1))
		if e != nil {
			return e
		}
		_, e = plist.Unmarshal(b, target)
		return e
	}
	var info struct {
		Executable string `plist:"CFBundleExecutable"`
	}
	var meta struct {
		ID int64 `plist:"itemId"`
	}
	if readPlist(infoFile, &info) != nil || readPlist(metadata, &meta) != nil || meta.ID != appID || info.Executable == "" || strings.ContainsAny(info.Executable, "/\\") {
		return zero, errors.New("package_identity_mismatch")
	}
	prefix := strings.TrimSuffix(infoFile.Name, "Info.plist")
	var executable *zip.File
	licensed := false
	for _, f := range z.File {
		if f.Name == prefix+info.Executable {
			executable = f
		}
		if strings.HasPrefix(f.Name, prefix) && strings.HasSuffix(f.Name, ".sinf") && f.UncompressedSize64 > 0 {
			licensed = true
		}
	}
	if executable == nil {
		return zero, errors.New("executable_missing")
	}
	if requireLicense && !licensed {
		return zero, errors.New("license_data_missing")
	}
	r, e := executable.Open()
	if e != nil {
		return zero, e
	}
	defer r.Close()
	h := sha256.New()
	if _, e = io.Copy(h, r); e != nil {
		return zero, e
	}
	var digest [32]byte
	copy(digest[:], h.Sum(nil))
	return digest, nil
}
