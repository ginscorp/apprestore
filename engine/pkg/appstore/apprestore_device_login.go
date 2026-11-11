package appstore

import (
	"context"
	"encoding/base64"
	"errors"
	"strings"
	"time"

	deviceassets "github.com/majd/ipatool/v2/internal/storedevice/sap/assets"
	devicemachine "github.com/majd/ipatool/v2/internal/storedevice/sap/machine"
	"github.com/majd/ipatool/v2/internal/storedevice/storeauth"
	"github.com/majd/ipatool/v2/pkg/http"
)

const deviceStateKey = "apprestore-store-device-v4"
const storeProvisioningURL = "https://auth.itunes.apple.com/auth/v1/otp/1.5/finish"

// Challenge bytes remain private to the protocol. Error/diagnostics expose only
// the fixed RP/SP action, never opaque challenge data or response headers.
type authenticationMachineActionError struct{ action, data string }

func (e *authenticationMachineActionError) Error() string {
	return "Apple requested device provisioning"
}
func (e *authenticationMachineActionError) AppleMachineAction() string { return e.action }

type deviceAuthenticationError struct {
	stage string
	cause error
}

func (e *deviceAuthenticationError) Error() string {
	return "Apple device authentication failed at " + e.stage
}
func (e *deviceAuthenticationError) Unwrap() error               { return e.cause }
func (e *deviceAuthenticationError) AuthenticationStage() string { return e.stage }

func (t *appstore) deviceLogin(input LoginInput) (LoginOutput, error) {
	if _, err := normalizeAuthCode(input.AuthCode); err != nil {
		return LoginOutput{}, err
	}
	t.deviceAuthMu.Lock()
	defer t.deviceAuthMu.Unlock()
	ctx := t.deviceAuthContext
	if ctx == nil {
		ctx = context.Background()
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Minute)
	defer cancel()
	fail := func(stage string, err error) (LoginOutput, error) {
		return LoginOutput{}, &deviceAuthenticationError{stage, err}
	}
	if t.keychain == nil {
		return fail("state", errors.New("memory state is not configured"))
	}
	mac, err := t.machine.MacAddress()
	if err != nil {
		return fail("identity", err)
	}
	guid, hardware, err := machineIdentity(mac)
	if err != nil {
		return fail("identity", err)
	}
	bag, err := t.bag(guid)
	if err != nil {
		return fail("configuration", err)
	}
	if !strings.HasPrefix(bag.AuthEndpoint, "https://auth.itunes.apple.com/") {
		return t.legacyLogin(input)
	}
	state, _ := t.keychain.Get(deviceStateKey)
	defer func() { clear(state); t.authenticationHeaders = nil }()
	save := func(next []byte) error { clear(state); state = next; return t.keychain.Set(deviceStateKey, next) }
	if len(state) > 0 {
		proof, next, proofErr := storeauth.StoreAMDHeaders(ctx, state, bag.AuthEndpoint, hardware)
		if proofErr == nil {
			if err = save(next); err != nil {
				return fail("state", err)
			}
			t.authenticationHeaders = proof
			return t.legacyLogin(input)
		}
	}
	client := storeauth.NewHTTPClient(nil)
	defer client.CloseIdleConnections()
	headers, next, err := storeauth.AnisetteHeaders(ctx, client, state)
	if err != nil {
		return fail("machine_provisioning", err)
	}
	if err = save(next); err != nil {
		return fail("state", err)
	}
	t.authenticationHeaders = map[string]string{}
	for key, values := range headers {
		if len(values) > 0 {
			t.authenticationHeaders[key] = values[0]
		}
	}
	// Complete machine negotiation without sending the user's credentials.
	// The final login alone carries the manually entered password and 2FA.
	_, err = t.legacyLogin(LoginInput{})
	var action *authenticationMachineActionError
	if !errors.As(err, &action) {
		if machineNegotiationReachedCredentials(err) {
			return t.legacyLogin(input)
		}
		return fail("store_challenge", err)
	}
	if action.action == "RP" {
		for key := range t.authenticationHeaders {
			if strings.EqualFold(key, "X-Apple-I-MD") || strings.EqualFold(key, "X-Apple-I-MD-M") || strings.EqualFold(key, "X-Apple-I-MD-RINFO") {
				delete(t.authenticationHeaders, key)
			}
		}
		_, err = t.legacyLogin(LoginInput{})
		action = nil
		if !errors.As(err, &action) {
			if machineNegotiationReachedCredentials(err) {
				return t.legacyLogin(input)
			}
			return fail("store_challenge", err)
		}
	}
	if action.action != "SP" {
		return fail("store_challenge", err)
	}
	bundle, err := deviceassets.Load(ctx)
	if err != nil {
		return fail("assets", err)
	}
	kb, err := devicemachine.GenerateKBSync(ctx, bundle, hardware, ^uint64(1))
	if err != nil {
		return fail("key_exchange", err)
	}
	next, err = storeauth.ProvisionStoreAnisette(ctx, client, state, action.data, storeProvisioningURL, storeAuthenticationUserAgent, base64.StdEncoding.EncodeToString(kb), hardware, headers)
	clear(kb)
	if err != nil {
		return fail("store_provisioning", err)
	}
	if err = save(next); err != nil {
		return fail("state", err)
	}
	proof, next, err := storeauth.StoreAMDHeaders(ctx, state, bag.AuthEndpoint, hardware)
	if err != nil {
		return fail("store_proof", err)
	}
	if err = save(next); err != nil {
		return fail("state", err)
	}
	t.authenticationHeaders = proof
	result, err := t.legacyLogin(input)
	if errors.As(err, &action) {
		return fail("store_verification", err)
	}
	return result, err
}

func machineNegotiationReachedCredentials(err error) bool {
	if errors.Is(err, ErrAuthCodeRequired) {
		return true
	}
	var apple *Error
	if !errors.As(err, &apple) {
		return false
	}
	var data loginResult
	switch response := apple.Metadata.(type) {
	case http.Result[loginResult]:
		data = response.Data
	case *http.Result[loginResult]:
		if response == nil {
			return false
		}
		data = response.Data
	default:
		return false
	}
	return data.FailureType == FailureTypeInvalidCredentials
}
