package appstore

import (
	"context"
	"errors"
	storehttp "github.com/majd/ipatool/v2/pkg/http"
	"strings"
	"testing"
)

type proofMemory map[string][]byte

func (m proofMemory) Get(k string) ([]byte, error) {
	v, ok := m[k]
	if !ok {
		return nil, errors.New("missing")
	}
	return append([]byte(nil), v...), nil
}
func (m proofMemory) Set(k string, v []byte) error { m[k] = append([]byte(nil), v...); return nil }
func (m proofMemory) Remove(k string) error        { delete(m, k); return nil }

func TestCommerceProofBoundToEveryDestination(t *testing.T) {
	memory := proofMemory{deviceStateKey: []byte("SYNTHETIC_STATE")}
	proofCalls, sends := 0, 0
	api := &appstore{deviceAuthEnabled: true, keychain: memory}
	api.deviceProofGenerator = func(ctx context.Context, state []byte, endpoint string, id []byte) (map[string]string, []byte, error) {
		proofCalls++
		if endpoint == "" || len(id) != 6 || string(state) != "SYNTHETIC_STATE" {
			t.Fatal("wrong proof identity")
		}
		return map[string]string{"X-Apple-AMD": "SYNTHETIC_PROOF", "X-Apple-AMD-M": "SYNTHETIC_MACHINE"}, []byte("SYNTHETIC_STATE"), nil
	}
	api.downloadClient = fixtureClient[downloadResult]{send: func(r storehttp.Request) (storehttp.Result[downloadResult], error) {
		sends++
		if !r.NoRedirects {
			t.Fatal("endpoint-bound proof could be replayed by redirect")
		}
		if r.Headers["X-Apple-AMD"] != "SYNTHETIC_PROOF" || r.Headers["X-Apple-AMD-M"] != "SYNTHETIC_MACHINE" {
			t.Fatal("commerce request lost device proof")
		}
		return storehttp.Result[downloadResult]{StatusCode: 200}, nil
	}}
	for _, path := range []string{PrivateAppStoreAPIPathDownload, redownloadProductPath, updateProductPath, entDownloadPath} {
		_, err := api.sendCommerceDownloadRequest(context.Background(), storehttp.Request{URL: "https://buy.itunes.apple.com" + path}, "001122334455")
		if err != nil {
			t.Fatal(err)
		}
	}
	if proofCalls != 4 || sends != 4 {
		t.Fatal("proof not regenerated per request")
	}
	api.deviceProofGenerator = func(context.Context, []byte, string, []byte) (map[string]string, []byte, error) {
		return nil, nil, errors.New("synthetic failure")
	}
	if _, err := api.sendCommerceDownloadRequest(context.Background(), storehttp.Request{URL: "https://buy.itunes.apple.com/request"}, "001122334455"); err == nil || sends != 4 {
		t.Fatal("request sent after failed proof")
	}
}

func TestDelistedEntitlementDoesNotRequirePublicVersion(t *testing.T) {
	for _, status := range []int{404, 503} {
		t.Run(strings.Repeat("x", status/100), func(t *testing.T) {
			generated, sent := 0, 0
			api := &appstore{}
			api.platformClient = fixtureClient[platformVersionLookupResult]{send: func(r storehttp.Request) (storehttp.Result[platformVersionLookupResult], error) {
				if strings.Contains(r.URL, "apps.apple.com") {
					return storehttp.Result[platformVersionLookupResult]{StatusCode: status}, nil
				}
				return storehttp.Result[platformVersionLookupResult]{StatusCode: 200}, nil
			}}
			api.kbsyncGenerator = func(context.Context, []byte, uint64) ([]byte, error) {
				generated++
				return []byte("SYNTHETIC_KBSYNC"), nil
			}
			api.downloadClient = fixtureClient[downloadResult]{send: func(r storehttp.Request) (storehttp.Result[downloadResult], error) {
				sent++
				if !strings.Contains(r.URL, entDownloadPath) {
					t.Fatal("unexpected commerce endpoint")
				}
				if _, present := r.Payload.(*storehttp.XMLPayload).Content["externalVersionId"]; present {
					t.Fatal("invented version for delisted app")
				}
				return storehttp.Result[downloadResult]{StatusCode: 200, Data: downloadResult{Items: []downloadItemResult{{URL: "https://a.mzstatic.com/synthetic.ipa", Metadata: map[string]interface{}{"itemId": 42, "softwareVersionExternalIdentifier": 1001, "softwareVersionBundleId": "com.example.synthetic"}}}}}, nil
			}}
			_, _, err := api.sendPreferredDownload(context.Background(), "https://downloaddispatch.itunes.apple.com"+entDownloadPath, Account{DirectoryServicesID: "123", StoreFront: "143469-2,29"}, App{ID: 42}, "001122334455", "", PlatformIPhone)
			if status == 404 {
				if err != nil || generated != 1 || sent != 1 {
					t.Fatal("confirmed delisting blocked entitlement request", err)
				}
			} else if err == nil || generated != 0 || sent != 0 {
				t.Fatal("network/server failure treated as confirmed delisting")
			}
		})
	}
}
