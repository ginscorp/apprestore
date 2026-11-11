package assets

import (
	"context"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"testing"
)

type blockedSyntheticTransport struct{ calls int }

func (x *blockedSyntheticTransport) RoundTrip(*http.Request) (*http.Response, error) {
	x.calls++
	return nil, errors.New("synthetic transport: network forbidden")
}

func TestSyntheticAssetWritesPreserveExisting(t *testing.T) {
	dir, err := os.MkdirTemp("", "apprestore-synthetic-assets-")
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "asset")
	if err = os.WriteFile(path, []byte("SYNTHETIC-EXISTING"), 0600); err != nil {
		t.Fatal(err)
	}
	if err = replaceFile(path, []byte("SYNTHETIC-NEW")); err == nil {
		t.Fatal("existing file was accepted")
	}
	got, err := os.ReadFile(path)
	if err != nil || string(got) != "SYNTHETIC-EXISTING" {
		t.Fatal("existing file changed")
	}
	newPath := filepath.Join(dir, "new-asset")
	if err = replaceFile(newPath, []byte("SYNTHETIC-NEW")); err != nil {
		t.Fatal(err)
	}
	got, err = os.ReadFile(newPath)
	if err != nil || string(got) != "SYNTHETIC-NEW" {
		t.Fatal("new file verification failed")
	}
	link := filepath.Join(dir, "link")
	if err = os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	if err = replaceFile(link, []byte("SYNTHETIC-NEW")); err == nil {
		t.Fatal("symlink accepted")
	}
}

func TestSyntheticPartialAssetsDoNotFetch(t *testing.T) {
	root, err := os.MkdirTemp("", "apprestore-synthetic-partial-")
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("APPRESTORE_MODERN_ASSETS", root)
	dir := filepath.Join(root, assetCacheDirectory)
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, requiredFiles[0].name), []byte("SYNTHETIC-PARTIAL"), 0600); err != nil {
		t.Fatal(err)
	}
	blocked := &blockedSyntheticTransport{}
	previous := http.DefaultTransport
	http.DefaultTransport = blocked
	defer func() { http.DefaultTransport = previous }()
	if _, err := Load(context.Background()); err == nil {
		t.Fatal("partial destination accepted")
	}
	if blocked.calls != 0 {
		t.Fatal("partial destination unexpectedly triggered network")
	}
}
