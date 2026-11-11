package appstore

import (
	"context"
	"errors"
	"strings"
	"testing"

	deviceassets "github.com/majd/ipatool/v2/internal/storedevice/sap/assets"
	storehttp "github.com/majd/ipatool/v2/pkg/http"
)

func TestDeviceActionDoesNotExposeChallenge(t *testing.T) {
	api := &appstore{}
	response := &storehttp.Result[loginResult]{StatusCode: 200, Headers: map[string]string{"X-Apple-AMD-Action": "SP", "X-Apple-AMD-Data": "SYNTHETIC_PRIVATE_CHALLENGE"}}
	retry, redirect, err := api.parseLoginResponse(response, 1, "", "https://auth.itunes.apple.com/auth/v1/native")
	var action *authenticationMachineActionError
	if retry || redirect != "" || !errors.As(err, &action) || action.action != "SP" {
		t.Fatal("device action not recognized")
	}
	if strings.Contains(err.Error(), "SYNTHETIC_PRIVATE_CHALLENGE") {
		t.Fatal("challenge leaked")
	}
	response.Headers["X-Apple-AMD-Action"] = "unrecognized"
	_, _, err = api.parseLoginResponse(response, 1, "", "https://auth.itunes.apple.com/auth/v1/native")
	if errors.As(err, &action) {
		t.Fatal("unrecognized challenge was actionable")
	}
}

func TestCanonicalProofHeadersReachStore(t *testing.T) {
	api := &appstore{authenticationHeaders: map[string]string{"X-Apple-I-Md": "SYNTHETIC_OTP", "X-Apple-I-Md-M": "SYNTHETIC_MACHINE"}}
	r := api.loginRequest("example@example.invalid", "SYNTHETIC_PASSWORD", "", "000000000000", "https://auth.itunes.apple.com/auth/v1/native", 1, nil)
	if r.Headers["X-Apple-AMD"] != "SYNTHETIC_OTP" || r.Headers["X-Apple-AMD-M"] != "SYNTHETIC_MACHINE" {
		t.Fatal("canonical header aliases lost")
	}
}

func TestNegotiationStopsBeforeCredentialsOnTransportFailure(t *testing.T) {
	if machineNegotiationReachedCredentials(errors.New("network error")) {
		t.Fatal("transport failure accepted as credential challenge")
	}
	response := storehttp.Result[loginResult]{StatusCode: 200, Data: loginResult{FailureType: FailureTypeInvalidCredentials}}
	if !machineNegotiationReachedCredentials(NewErrorWithMetadata(errors.New("synthetic"), response)) {
		t.Fatal("credential stage not recognized")
	}
}

func TestMissingDeviceRuntimeNeverDownloads(t *testing.T) {
	t.Setenv("APPRESTORE_RUNTIME", t.TempDir())
	// A normal runtime has no asset downloader. Missing files are a local error.
	_, err := deviceassets.Load(context.Background())
	if err == nil || err.Error() != "device_assets_missing" {
		t.Fatal("missing runtime accepted")
	}
}
