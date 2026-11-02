package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/majd/ipatool/v2/internal/netguard"
	"github.com/majd/ipatool/v2/pkg/appstore"
	storehttp "github.com/majd/ipatool/v2/pkg/http"
	"strings"
	"testing"
)

func TestSafeDiagnosticsNeverContainRawAppleSecrets(t *testing.T) {
	canary := "CANARY_PASSWORD_TOKEN_EMAIL_COOKIE"
	body := struct {
		FailureType     string
		CustomerMessage string
		Items           []string
	}{"2059", canary, nil}
	wrapped := appstore.NewErrorWithMetadata(errors.New(canary), struct {
		StatusCode int
		Data       struct {
			FailureType     string
			CustomerMessage string
			Items           []string
		}
	}{200, body})
	if got := safeAppleFailure(wrapped); got != "app_temporarily_unavailable" {
		t.Fatal(got)
	}
	diag := makeCheckDiagnostic(6756064549, "list_versions", errorCode(wrapped), nil)
	diag.ResponseSummary = summarizeCheckError(wrapped)
	data, _ := json.Marshal(diag)
	if strings.Contains(string(data), canary) {
		t.Fatal("raw response leaked")
	}
	if safeAppleFailure(fmt.Errorf("wrap: %w", context.DeadlineExceeded)) != "network_timeout" {
		t.Fatal("timeout")
	}
	for status, want := range map[int]string{401: "session_expired", 403: "apple_access_denied", 429: "apple_rate_limited", 503: "apple_service_unavailable"} {
		if got := safeAppleFailure(&storehttp.UnexpectedResponseError{StatusCode: status, Snippet: canary}); got != want {
			t.Fatal(status, got)
		}
	}
	netguard.BeginTrace()
	netguard.RecordTrace("/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct?"+canary, 200, false)
	events := netguard.EndTrace()
	data, _ = json.Marshal(events)
	if strings.Contains(string(data), canary) || len(events) != 1 || events[0].Step != "legacy_download" {
		t.Fatal("trace leaked URL")
	}
	netguard.RecordTrace(canary, 200, false)
	if len(netguard.EndTrace()) != 0 {
		t.Fatal("disabled trace retained data")
	}
}
