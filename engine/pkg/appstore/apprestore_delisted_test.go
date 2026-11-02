package appstore

import (
	"archive/zip"
	"context"
	"errors"
	storehttp "github.com/majd/ipatool/v2/pkg/http"
	"howett.net/plist"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

type fixtureClient[R any] struct {
	storehttp.Client[R]
	send func(storehttp.Request) (storehttp.Result[R], error)
}

func (c fixtureClient[R]) Send(r storehttp.Request) (storehttp.Result[R], error) { return c.send(r) }
func TestDelistedFallbackOnlyAfterCatalog404(t *testing.T) {
	for _, tc := range []struct {
		name      string
		status    int
		network   bool
		wantCalls int
		preferred bool
	}{
		{"delisted", 404, false, 1, false}, {"delisted_preferred_path", 404, false, 1, true}, {"malformed_public_metadata", 200, false, 0, false}, {"server_failure", 503, false, 0, false}, {"network_failure", 0, true, 0, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			acc := Account{StoreFront: "143467-2,29", DirectoryServicesID: "SYNTHETIC_ACCOUNT"}
			app := App{ID: 42, BundleID: "com.example.test"}
			guid := "001122334455"
			calls, unversioned := 0, 0
			s := &appstore{}
			if tc.preferred {
				s.kbsyncGenerator = func(context.Context, []byte, uint64) ([]byte, error) {
					t.Fatal("must not generate before catalog resolution")
					return nil, nil
				}
			}
			s.platformClient = fixtureClient[platformVersionLookupResult]{send: func(r storehttp.Request) (storehttp.Result[platformVersionLookupResult], error) {
				if strings.Contains(r.URL, "apps.apple.com") {
					return storehttp.Result[platformVersionLookupResult]{StatusCode: tc.status}, nil
				}
				if tc.network {
					return storehttp.Result[platformVersionLookupResult]{}, context.DeadlineExceeded
				}
				return storehttp.Result[platformVersionLookupResult]{StatusCode: 200}, nil
			}}
			s.bagClient = fixtureClient[bagResult]{send: func(r storehttp.Request) (storehttp.Result[bagResult], error) {
				return storehttp.Result[bagResult]{StatusCode: 200, Data: bagResult{URLBag: urlBag{EntDownloadEndpoint: "https://downloaddispatch.itunes.apple.com/WebObjects/DownloadDispatch.woa/wa/ent/download", RedownloadEndpoint: "https://downloaddispatch.itunes.apple.com/r/redownload"}}}, nil
			}}
			s.downloadClient = fixtureClient[downloadResult]{send: func(r storehttp.Request) (storehttp.Result[downloadResult], error) {
				calls++
				if strings.Contains(r.URL, "volumeStoreDownloadProduct") {
					return storehttp.Result[downloadResult]{StatusCode: 200}, nil
				}
				unversioned++
				if !strings.HasPrefix(r.URL, "https://downloaddispatch.itunes.apple.com/r/redownload?") {
					t.Fatal("unexpected endpoint")
				}
				body := r.Payload.(*storehttp.XMLPayload).Content
				if _, ok := body["appExtVrsId"]; ok {
					t.Fatal("unexpected version")
				}
				if body["salableAdamId"] != app.ID {
					t.Fatal("different app")
				}
				expected := s.downloadProductRequest(s.volumeStoreEndpoint(acc), acc, app, guid, "").Headers
				if !reflect.DeepEqual(r.Headers, expected) {
					t.Fatal("account/session headers changed")
				}
				deadline, ok := r.Context.Deadline()
				if !ok || time.Until(deadline) > 31*time.Second {
					t.Fatal("unbounded request")
				}
				return storehttp.Result[downloadResult]{StatusCode: 200, Data: downloadResult{Items: []downloadItemResult{{URL: "https://a.mzstatic.com/test.ipa", Metadata: map[string]interface{}{"itemId": uint64(42), "softwareVersionBundleId": app.BundleID, "softwareVersionExternalIdentifier": uint64(1001)}}}}}, nil
			}}
			out, p, err := s.sendDownloadProduct(context.Background(), acc, app, guid, "", PlatformIPhone)
			if unversioned != tc.wantCalls {
				t.Fatalf("unexpected fallback count %d", unversioned)
			}
			if tc.wantCalls == 1 {
				if err != nil || p != PlatformIPhone || len(out.Data.Items) != 1 || calls != 2 {
					t.Fatal("fallback did not complete")
				}
			} else if err == nil {
				t.Fatal("unsafe catalog failure ignored")
			}
		})
	}
}
func TestDelistedResponseValidationAndLicenseFailures(t *testing.T) {
	app := App{ID: 42, BundleID: "com.example.test"}
	good := storehttp.Result[downloadResult]{StatusCode: 200, Data: downloadResult{Items: []downloadItemResult{{URL: "https://a.mzstatic.com/test.ipa", Metadata: map[string]interface{}{"itemId": 42, "softwareVersionBundleId": app.BundleID, "softwareVersionExternalIdentifier": 1001}}}}}
	if validateDownloadResponse(good, app, "", "redownload") != nil {
		t.Fatal("unversioned valid identity rejected")
	}
	for _, v := range []struct {
		key   string
		value any
	}{{"itemId", 43}, {"softwareVersionBundleId", "com.other.app"}} {
		bad := good
		bad.Data.Items = append([]downloadItemResult(nil), good.Data.Items...)
		m := map[string]interface{}{}
		for k, x := range good.Data.Items[0].Metadata {
			m[k] = x
		}
		m[v.key] = v.value
		bad.Data.Items[0].Metadata = m
		if validateDownloadResponse(bad, app, "", "redownload") == nil {
			t.Fatal("wrong identity accepted")
		}
	}
	if validateDownloadResponse(good, app, "2002", "redownload") == nil {
		t.Fatal("explicit version changed")
	}
	for _, failure := range []string{FailureTypeLicenseNotFound, FailureTypePasswordTokenExpired} {
		s := &appstore{downloadClient: fixtureClient[downloadResult]{send: func(r storehttp.Request) (storehttp.Result[downloadResult], error) {
			return storehttp.Result[downloadResult]{StatusCode: 200, Data: downloadResult{FailureType: failure}}, nil
		}}}
		out, err := s.sendUnpinnedRedownload(context.Background(), downloadProductEndpoint{baseURL: "https://downloaddispatch.itunes.apple.com/r/redownload"}, Account{}, app, "001122334455")
		if err != nil || out.Data.FailureType != failure {
			t.Fatal("Apple failure suppressed")
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	s := &appstore{}
	if _, err := s.sendUnpinnedRedownload(ctx, downloadProductEndpoint{}, Account{}, app, ""); !errors.Is(err, context.Canceled) {
		t.Fatal("cancellation ignored")
	}
}
func TestUnversionedFallbackStillRejectsTVPackage(t *testing.T) {
	p := filepath.Join(t.TempDir(), "tv.ipa")
	f, _ := os.Create(p)
	z := zip.NewWriter(f)
	entry, _ := z.Create("Payload/Test.app/Info.plist")
	data, _ := plist.Marshal(map[string]any{"CFBundleSupportedPlatforms": []string{"AppleTVOS"}}, plist.XMLFormat)
	entry.Write(data)
	z.Close()
	f.Close()
	if (&appstore{}).validatePackagePlatform(p, PlatformIPhone) == nil {
		t.Fatal("tvOS package allowed on iPhone")
	}
}
