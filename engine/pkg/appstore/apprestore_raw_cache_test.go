package appstore

import (
	"archive/zip"
	"os"
	"path/filepath"
	"testing"
)

func rawFixture(t *testing.T, root, extra string) string {
	t.Helper()
	f, e := os.CreateTemp(root, "raw-")
	if e != nil {
		t.Fatal(e)
	}
	z := zip.NewWriter(f)
	for name, data := range map[string]string{"Payload/Test.app/Info.plist": "synthetic-info", "Payload/Test.app/Test": "synthetic-encrypted-executable"} {
		w, e := z.Create(name)
		if e != nil {
			t.Fatal(e)
		}
		w.Write([]byte(data))
	}
	if extra != "" {
		w, _ := z.Create(extra)
		w.Write([]byte("DO_NOT_CACHE_ACCOUNT_DATA"))
	}
	if e = z.Close(); e != nil {
		t.Fatal(e)
	}
	f.Close()
	return f.Name()
}
func TestRawCacheReusesOnlyExactVerifiedPayload(t *testing.T) {
	r := t.TempDir()
	p := rawFixture(t, r, "")
	_, md, _, _ := rawDigests(p)
	c := &RawPackageCache{Root: filepath.Join(r, "cache")}
	if !c.Store(123, PlatformIPhone, md, p) {
		t.Fatal("store")
	}
	out := filepath.Join(r, "download.tmp")
	if !c.Load(123, PlatformIPhone, md, out) {
		t.Fatal("load")
	}
	if c.Load(456, PlatformIPhone, md, filepath.Join(r, "wrong.tmp")) {
		t.Fatal("cross app")
	}
	if c.Load(123, PlatformIPad, md, filepath.Join(r, "platform.tmp")) {
		t.Fatal("cross platform")
	}
	if !rawEligible(out) {
		t.Fatal("personalized payload")
	}
	files, _ := os.ReadDir(c.Root)
	for _, f := range files {
		if filepath.Ext(f.Name()) == ".rawipa" {
			os.WriteFile(filepath.Join(c.Root, f.Name()), []byte("corrupt"), 0600)
		}
	}
	if c.Load(123, PlatformIPhone, md, filepath.Join(r, "corrupt.tmp")) {
		t.Fatal("corrupt cache trusted")
	}
}
func TestRawCacheRejectsPersonalizedPackages(t *testing.T) {
	for _, name := range []string{"iTunesMetadata.plist", "Payload/Test.app/SC_Info/Test.sinf", "Payload/Test.app/SC_Info/Test.supp"} {
		r := t.TempDir()
		p := rawFixture(t, r, name)
		_, md, _, _ := rawDigests(p)
		if (&RawPackageCache{Root: filepath.Join(r, "cache")}).Store(123, PlatformIPhone, md, p) {
			t.Fatal("account data cached", name)
		}
	}
}
func TestRawCacheBoundPreservesExistingPayload(t *testing.T) {
	r := t.TempDir()
	p := rawFixture(t, r, "")
	_, md, _, _ := rawDigests(p)
	c := &RawPackageCache{Root: filepath.Join(r, "cache"), MaxPackages: 1}
	if !c.Store(1, PlatformIPhone, md, p) {
		t.Fatal("first")
	}
	if c.Store(2, PlatformIPhone, md, p) {
		t.Fatal("budget exceeded")
	}
	if !c.Load(1, PlatformIPhone, md, filepath.Join(r, "copy.tmp")) {
		t.Fatal("keeper lost")
	}
}
