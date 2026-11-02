package appstore

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/md5"
	"errors"
	"fmt"
	storehttp "github.com/majd/ipatool/v2/pkg/http"
	"github.com/majd/ipatool/v2/pkg/util/machine"
	"github.com/majd/ipatool/v2/pkg/util/operatingsystem"
	"howett.net/plist"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type fixtureMachine struct{ machine.Machine }

func (fixtureMachine) MacAddress() (string, error) { return "00:11:22:33:44:55", nil }

type fixturePayloadClient struct {
	storehttp.Client[interface{}]
	payload []byte
	length  int64
	calls   int
}

func (*fixturePayloadClient) NewRequest(method, url string, body io.Reader) (*http.Request, error) {
	return http.NewRequest(method, url, body)
}
func (c *fixturePayloadClient) Do(*http.Request) (*http.Response, error) {
	c.calls++
	return &http.Response{StatusCode: 200, ContentLength: c.length, Body: io.NopCloser(bytes.NewReader(c.payload))}, nil
}

func TestFreshDownloadIntegrityWithoutCache(t *testing.T) {
	var raw bytes.Buffer
	z := zip.NewWriter(&raw)
	info, _ := plist.Marshal(map[string]any{"CFBundleExecutable": "Main", "CFBundleSupportedPlatforms": []string{"iPhoneOS"}}, plist.XMLFormat)
	w, _ := z.Create("Payload/Test.app/Info.plist")
	w.Write(info)
	w, _ = z.Create("Payload/Test.app/Main")
	w.Write([]byte("FIXTURE_EXECUTABLE"))
	z.Close()
	good := fmt.Sprintf("%x", md5.Sum(raw.Bytes()))
	for _, tc := range []struct {
		name, hash string
		wrongApp   bool
		wantOK     bool
	}{{"good", good, false, true}, {"corrupt", strings.Repeat("0", 32), false, false}, {"missing_hash", "", false, false}, {"wrong_app", good, true, false}} {
		t.Run(tc.name, func(t *testing.T) {
			payload := &fixturePayloadClient{payload: raw.Bytes(), length: int64(raw.Len())}
			s := &appstore{os: operatingsystem.New(), machine: fixtureMachine{}, httpClient: payload}
			s.downloadClient = fixtureClient[downloadResult]{send: func(storehttp.Request) (storehttp.Result[downloadResult], error) {
				id := 42
				if tc.wrongApp {
					id = 43
				}
				return storehttp.Result[downloadResult]{StatusCode: 200, Data: downloadResult{Items: []downloadItemResult{{URL: "https://a.mzstatic.com/fixture.ipa", HashMD5: tc.hash, Metadata: map[string]interface{}{"itemId": id, "softwareVersionBundleId": "com.fixture.app", "softwareVersionExternalIdentifier": 1001}}}}}, nil
			}}
			dest := filepath.Join(t.TempDir(), "application.ipa")
			_, err := s.Download(DownloadInput{Context: context.Background(), App: App{ID: 42}, Platform: PlatformIPhone, OutputPath: dest})
			if (err == nil) != tc.wantOK {
				t.Fatalf("unexpected success state: %v", err)
			}
			if !tc.wantOK {
				if _, e := os.Stat(dest); !os.IsNotExist(e) {
					t.Fatal("failed package exposed")
				}
			}
			if tc.wrongApp && payload.calls != 0 {
				t.Fatal("downloaded mismatched app")
			}
		})
	}
}
func TestDownloadAndMetadataBounds(t *testing.T) {
	c := &fixturePayloadClient{length: maxIPAPayloadBytes + 1}
	s := &appstore{os: operatingsystem.New(), httpClient: c}
	err := s.downloadFile(context.Background(), "https://a.mzstatic.com/fixture.ipa", filepath.Join(t.TempDir(), "download.tmp"), nil)
	if !errors.Is(err, ErrPackageLimit) {
		t.Fatal("oversized download accepted")
	}
	if _, err := readPackageMetadata(&zip.File{FileHeader: zip.FileHeader{UncompressedSize64: maxPackageMetadataBytes + 1}}); !errors.Is(err, ErrPackageLimit) {
		t.Fatal("oversized metadata accepted")
	}
}
func TestSinfUsesMainAppNotFirstExtension(t *testing.T) {
	path := filepath.Join(t.TempDir(), "application.ipa")
	f, _ := os.Create(path)
	z := zip.NewWriter(f)
	for _, entry := range []struct{ path, executable string }{{"Payload/Main.app/PlugIns/Other.app/Info.plist", "Other"}, {"Payload/Main.app/Info.plist", "Main"}} {
		w, _ := z.Create(entry.path)
		b, _ := plist.Marshal(map[string]any{"CFBundleExecutable": entry.executable}, plist.XMLFormat)
		w.Write(b)
	}
	z.Close()
	f.Close()
	s := &appstore{os: operatingsystem.New()}
	if err := s.ReplicateSinf(ReplicateSinfInput{PackagePath: path, Sinfs: []Sinf{{Data: []byte("FIXTURE_LICENSE")}}}); err != nil {
		t.Fatal(err)
	}
	r, err := zip.OpenReader(path)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	found := false
	for _, f := range r.File {
		if strings.HasSuffix(f.Name, ".sinf") {
			if f.Name != "Payload/Main.app/SC_Info/Main.sinf" {
				t.Fatal("wrong license destination")
			}
			found = true
		}
	}
	if !found {
		t.Fatal("missing license")
	}
	var b bytes.Buffer
	w := zip.NewWriter(&b)
	if s.replicateSinfFromManifest(packageManifest{SinfPaths: []string{"../escape.sinf"}}, w, []Sinf{{Data: []byte("x")}}, "Main") == nil {
		t.Fatal("path traversal accepted")
	}
	w.Close()
}
