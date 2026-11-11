package main

import (
	"context"
	"errors"
	"github.com/majd/ipatool/v2/internal/netguard"
	"github.com/majd/ipatool/v2/pkg/appstore"
	storehttp "github.com/majd/ipatool/v2/pkg/http"
	"net"
	"reflect"
	"strings"
	"time"
)

// Inspect only allowlisted status/enum fields, never serialize Apple's response.
func safeAppleFailure(err error) string {
	if errors.Is(err, context.DeadlineExceeded) {
		return "network_timeout"
	}
	var n net.Error
	if errors.As(err, &n) {
		if n.Timeout() {
			return "network_timeout"
		}
		return "network_unavailable"
	}
	var unexpected *storehttp.UnexpectedResponseError
	status := 0
	if errors.As(err, &unexpected) {
		status = unexpected.StatusCode
	}
	var apple *appstore.Error
	if errors.As(err, &apple) && apple.Metadata != nil {
		v := reflect.ValueOf(apple.Metadata)
		if v.Kind() == reflect.Pointer {
			v = v.Elem()
		}
		if v.IsValid() && v.Kind() == reflect.Struct {
			if f := v.FieldByName("StatusCode"); f.IsValid() && f.Kind() == reflect.Int {
				status = int(f.Int())
			}
			d := v.FieldByName("Data")
			if d.IsValid() && d.Kind() == reflect.Struct {
				if f := d.FieldByName("FailureType"); f.IsValid() && f.Kind() == reflect.String {
					switch strings.ToLower(f.String()) {
					case "-5000":
						return "invalid_credentials"
					case "2059", "404", "itemnotavailable", "itemnotfound", "temporarilyunavailable":
						return "app_temporarily_unavailable"
					case "1008", "invalidkbsync", "deviceverificationfailed":
						return "apple_verification_failed"
					}
				}
			}
		}
	}
	switch status {
	case 401:
		return "session_expired"
	case 403:
		return "apple_access_denied"
	case 404:
		return "app_temporarily_unavailable"
	case 429:
		return "apple_rate_limited"
	}
	if status >= 500 {
		return "apple_service_unavailable"
	}
	return ""
}

type checkDiagnostic struct {
	ResponseSummary map[string]any        `json:"response_summary,omitempty"`
	Schema          int                   `json:"schema"`
	AppID           int64                 `json:"app_id"`
	CheckedAt       string                `json:"checked_at"`
	Stage           string                `json:"stage"`
	Code            string                `json:"code"`
	Requests        []netguard.TraceEvent `json:"requests"`
}

func makeCheckDiagnostic(id int64, stage, code string, events []netguard.TraceEvent) *checkDiagnostic {
	if code == "" {
		code = "ok"
	}
	return &checkDiagnostic{Schema: 1, AppID: id, CheckedAt: time.Now().UTC().Format(time.RFC3339), Stage: stage, Code: code, Requests: events}
}

func summarizeCheckError(err error) map[string]any {
	out := map[string]any{}
	var stage interface{ AuthenticationStage() string }
	if errors.As(err, &stage) {
		switch value := stage.AuthenticationStage(); value {
		case "state", "identity", "configuration", "machine_provisioning", "store_challenge", "assets", "key_exchange", "store_provisioning", "store_proof", "store_verification", "commerce_proof":
			out["device_stage"] = value
		}
	}
	var action interface{ AppleMachineAction() string }
	if errors.As(err, &action) {
		switch value := action.AppleMachineAction(); value {
		case "RP", "SP":
			out["machine_action"] = value
		}
	}
	var unexpected *storehttp.UnexpectedResponseError
	if errors.As(err, &unexpected) {
		out["http_status"] = unexpected.StatusCode
		switch unexpected.Reason {
		case "authentication redirect is missing Location":
			out["response_kind"] = "redirect_without_location"
		case "empty or non-plist authentication response":
			out["response_kind"] = "empty_or_non_plist"
		case "malformed authentication plist":
			out["response_kind"] = "malformed_plist"
		default:
			out["response_kind"] = "other"
		}
		return out
	}
	var apple *appstore.Error
	if !errors.As(err, &apple) || apple.Metadata == nil {
		return out
	}
	v := reflect.ValueOf(apple.Metadata)
	if v.Kind() == reflect.Pointer {
		v = v.Elem()
	}
	if !v.IsValid() || v.Kind() != reflect.Struct {
		return out
	}
	if f := v.FieldByName("StatusCode"); f.IsValid() && f.Kind() == reflect.Int {
		out["http_status"] = f.Int()
	}
	if f := v.FieldByName("Headers"); f.IsValid() && f.Kind() == reflect.Map {
		for _, key := range f.MapKeys() {
			if key.Kind() == reflect.String && strings.EqualFold(key.String(), "X-Apple-AMD-Action") {
				value := f.MapIndex(key)
				if value.Kind() == reflect.String {
					switch value.String() {
					case "RP", "SP":
						out["machine_action"] = value.String()
					default:
						out["machine_action"] = "unrecognized"
					}
				}
			}
		}
	}
	d := v.FieldByName("Data")
	if !d.IsValid() || d.Kind() != reflect.Struct {
		return out
	}
	if f := d.FieldByName("FailureType"); f.IsValid() && f.Kind() == reflect.String {
		code := f.String()
		switch code {
		case "-5000", "2034", "2042", "9610", "2059", "5002", "1008":
			out["apple_failure_type"] = code
		case "":
			out["apple_failure_type"] = "empty"
		default:
			out["apple_failure_type"] = "unrecognized"
		}
	}
	if f := d.FieldByName("Items"); f.IsValid() && f.Kind() == reflect.Slice {
		out["item_count"] = f.Len()
	}
	if f := d.FieldByName("CustomerMessage"); f.IsValid() && f.Kind() == reflect.String {
		m := strings.ToLower(f.String())
		category := "unrecognized"
		switch {
		case m == "":
			category = "empty"
		case strings.Contains(m, "no longer available"), strings.Contains(m, "not available"):
			category = "not_available"
		case strings.Contains(m, "not purchased"), strings.Contains(m, "license"):
			category = "ownership"
		case strings.Contains(m, "temporarily"):
			category = "temporary"
		}
		out["message_category"] = category
	}
	return out
}
