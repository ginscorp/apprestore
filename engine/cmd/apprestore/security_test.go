package main

import (
	"archive/zip"
	"context"
	"encoding/json"
	"github.com/majd/ipatool/v2/internal/netguard"
	"github.com/majd/ipatool/v2/pkg/appstore"
	"github.com/majd/ipatool/v2/pkg/util/operatingsystem"
	"howett.net/plist"
	"net/http"
	"net/url"
	"os"
	"strings"
	"testing"
)

func TestPasswordNeverRetained(t *testing.T) {
	m := newMemory()
	a := appstore.Account{Email: "synthetic@example.invalid", Password: "CANARY_PASSWORD", PasswordToken: "CANARY_TOKEN"}
	b, _ := json.Marshal(a)
	if err := m.Set("account", b); err != nil {
		t.Fatal(err)
	}
	got, _ := m.Get("account")
	if strings.Contains(string(got), "CANARY_PASSWORD") {
		t.Fatal("password retained")
	}
	if !strings.Contains(string(got), "CANARY_TOKEN") {
		t.Fatal("token missing")
	}
	m.Close()
	if _, err := m.Get("account"); err == nil {
		t.Fatal("account survived close")
	}
}

type downloadStub struct {
	appstore.AppStore
	ids         []int64
	skipLicense bool
}

func (f *downloadStub) Download(q appstore.DownloadInput) (appstore.DownloadOutput, error) {
	f.ids = append(f.ids, q.App.ID)
	file, err := os.Create(q.OutputPath)
	if err != nil {
		return appstore.DownloadOutput{}, err
	}
	z := zip.NewWriter(file)
	info, _ := plist.Marshal(map[string]any{"CFBundleExecutable": "Test", "CFBundleIdentifier": "test.synthetic"}, plist.XMLFormat)
	metadata, _ := plist.Marshal(map[string]any{"itemId": q.App.ID}, plist.XMLFormat)
	for name, data := range map[string][]byte{"Payload/Test.app/Info.plist": info, "Payload/Test.app/Test": []byte("UNCHANGED_SYNTHETIC_EXECUTABLE"), "iTunesMetadata.plist": metadata} {
		w, e := z.Create(name)
		if e != nil {
			return appstore.DownloadOutput{}, e
		}
		if _, e = w.Write(data); e != nil {
			return appstore.DownloadOutput{}, e
		}
	}
	err = z.Close()
	closeErr := file.Close()
	if err == nil {
		err = closeErr
	}
	return appstore.DownloadOutput{DestinationPath: q.OutputPath, Sinfs: []appstore.Sinf{{ID: q.App.ID, Data: []byte("SYNTHETIC_APPLE_LICENSE")}}}, err
}
func (f *downloadStub) ReplicateSinf(q appstore.ReplicateSinfInput) error {
	if f.skipLicense {
		return nil
	}
	return f.AppStore.ReplicateSinf(q)
}
func newDownloadStub() *downloadStub {
	return &downloadStub{AppStore: appstore.NewAppStore(appstore.Args{OperatingSystem: operatingsystem.New()})}
}
func TestSeveralDownloadsKeepOneAccount(t *testing.T) {
	t.Setenv("TMPDIR", t.TempDir())
	api := newDownloadStub()
	mem := newMemory()
	_ = mem.Set("token", []byte("SYNTHETIC_SESSION"))
	s := &session{api: api, store: mem, account: appstore.Account{DirectoryServicesID: "SYNTHETIC_ACCOUNT"}}
	t.Cleanup(func() { _ = s.close() })
	if r := s.handle(context.Background(), request{Action: "download", AppID: 1, Confirmed: true}); !r.OK {
		t.Fatal(r)
	}
	first := s.packagePath
	if r := s.handle(context.Background(), request{Action: "download", AppID: 2, Confirmed: true}); !r.OK {
		t.Fatal(r)
	}
	if s.api != api || s.account.DirectoryServicesID != "SYNTHETIC_ACCOUNT" {
		t.Fatal("account was replaced")
	}
	if token, e := mem.Get("token"); e != nil || string(token) != "SYNTHETIC_SESSION" {
		t.Fatal("session lost")
	}
	if _, e := os.Stat(first); !os.IsNotExist(e) {
		t.Fatal("previous temporary package retained")
	}
	if len(api.ids) != 2 || api.ids[0] != 1 || api.ids[1] != 2 {
		t.Fatal("wrong package")
	}
	if r := s.handle(context.Background(), request{Action: "close"}); !r.OK {
		t.Fatal(r)
	}
	if _, e := mem.Get("token"); e == nil {
		t.Fatal("session survived close")
	}
}
func TestMissingLicenseNeverExposesInstallablePackage(t *testing.T) {
	t.Setenv("TMPDIR", t.TempDir())
	api := newDownloadStub()
	api.skipLicense = true
	s := &session{api: api}
	t.Cleanup(func() { _ = s.close() })
	r := s.handle(t.Context(), request{Action: "download", AppID: 123, Confirmed: true})
	if r.OK || r.Error != "license_data_missing" || s.packagePath != "" {
		t.Fatal("unlicensed package exposed", r)
	}
}
func TestAppleHostBoundary(t *testing.T) {
	for _, host := range []string{"apple.com.evil.invalid", "evilapple.com", "localhost", "127.0.0.1", "github.com"} {
		if netguard.AppleHost(host) {
			t.Fatal(host)
		}
	}
	for _, host := range []string{"buy.itunes.apple.com", "itunes.apple.com", "a1.mzstatic.com"} {
		if !netguard.AppleHost(host) {
			t.Fatal(host)
		}
	}
}
func TestCatalogMergeUsesID(t *testing.T) {
	a, _ := parseCatalog([]byte("Online: 123\nOnline: 456\n"), "lines", "a")
	b, _ := parseCatalog([]byte(`{"apps":[{"id":123,"name":"Новое имя"}]}`), "json", "b")
	got := mergeCatalog(a, b)
	if len(got) != 2 || len(got[0].Aliases) != 2 || len(got[0].Sources) != 2 {
		t.Fatal(got)
	}
}
func TestRejectInvalidCatalog(t *testing.T) {
	for _, test := range []struct{ kind, data string }{{"json", `{"apps":[]}`}, {"lines", "Name: ;curl bad"}, {"csv", "name,other\nx,1"}, {"json", `{"apps":[{"id":0,"name":"bad"}]}`}} {
		if _, err := parseCatalog([]byte(test.data), test.kind, "x"); err == nil {
			t.Fatal(test)
		}
	}
}
func TestPublicRequestsCannotSendToOtherPaths(t *testing.T) {
	u, _ := url.Parse("https://raw.githubusercontent.com/evil/exfil")
	_, err := (publicTransport{}).RoundTrip(&http.Request{URL: u, Method: "GET"})
	if err == nil {
		t.Fatal("accepted unrelated path")
	}
}
func TestActionsRequireSessionAndConfirmation(t *testing.T) {
	s := &session{}
	if r := s.handle(t.Context(), request{Action: "download", AppID: 123, Confirmed: true}); r.Error != "not_authenticated" {
		t.Fatal(r)
	}
	if r := s.handle(t.Context(), request{Action: "close"}); !r.OK {
		t.Fatal(r)
	}
}
