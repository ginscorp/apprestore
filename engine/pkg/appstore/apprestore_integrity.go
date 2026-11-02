package appstore

import (
	"archive/zip"
	"errors"
	"io"
	"strings"
)

const maxIPAPayloadBytes int64 = 4 << 30
const maxPackageMetadataBytes = 4 << 20

var ErrPackageIntegrity = errors.New("package_integrity_failed")
var ErrPackageLimit = errors.New("package_size_limit")

// Apple supplies MD5 for transport integrity. This is not a replacement for iOS code signing.
// Verification is mandatory even when the optional shared cache is disabled or full.
func verifyIPAPayload(path, expected string) error {
	if !rawDigestPattern.MatchString(expected) {
		return ErrPackageIntegrity
	}
	n, actual, _, err := rawDigests(path)
	if err != nil {
		return err
	}
	if n <= 0 || n > maxIPAPayloadBytes {
		return ErrPackageLimit
	}
	if !strings.EqualFold(actual, expected) {
		return ErrPackageIntegrity
	}
	return nil
}

func readPackageMetadata(file *zip.File) ([]byte, error) {
	if file.UncompressedSize64 > maxPackageMetadataBytes {
		return nil, ErrPackageLimit
	}
	r, err := file.Open()
	if err != nil {
		return nil, err
	}
	defer r.Close()
	b, err := io.ReadAll(io.LimitReader(r, maxPackageMetadataBytes+1))
	if len(b) > maxPackageMetadataBytes {
		return nil, ErrPackageLimit
	}
	return b, err
}
