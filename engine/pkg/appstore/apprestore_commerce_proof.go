package appstore

import (
	"context"
	"encoding/hex"
	"errors"

	deviceassets "github.com/majd/ipatool/v2/internal/storedevice/sap/assets"
	devicemachine "github.com/majd/ipatool/v2/internal/storedevice/sap/machine"
	"github.com/majd/ipatool/v2/internal/storedevice/storeauth"
	"github.com/majd/ipatool/v2/pkg/http"
)

func deviceKBSyncGenerator(ctx context.Context, hardware []byte, dsid uint64) ([]byte, error) {
	bundle, err := deviceassets.Load(ctx)
	if err != nil {
		return nil, err
	}
	return devicemachine.GenerateKBSync(ctx, bundle, hardware, dsid)
}

// Native Store tokens require a fresh type-2 proof for each commerce URL too.
// The login proof is not reused for another endpoint and is never persisted.
func (t *appstore) sendCommerceDownloadRequest(ctx context.Context, request http.Request, guid string) (http.Result[downloadResult], error) {
	if ctx == nil {
		ctx = context.Background()
	}
	request.Context = ctx
	if t.deviceAuthEnabled {
		// Proof is bound to this exact endpoint. Never replay it on a redirect.
		request.NoRedirects = true
		t.deviceAuthMu.Lock()
		defer t.deviceAuthMu.Unlock()
		hardware, err := hex.DecodeString(guid)
		if err != nil || len(hardware) != 6 {
			return http.Result[downloadResult]{}, errors.New("invalid commerce device identity")
		}
		if t.keychain == nil {
			return http.Result[downloadResult]{}, ErrPasswordTokenExpired
		}
		state, err := t.keychain.Get(deviceStateKey)
		if err != nil || len(state) == 0 {
			return http.Result[downloadResult]{}, ErrPasswordTokenExpired
		}
		defer clear(state)
		if err = ctx.Err(); err != nil {
			return http.Result[downloadResult]{}, err
		}
		generator := t.deviceProofGenerator
		if generator == nil {
			generator = storeauth.StoreAMDHeaders
		}
		proof, next, err := generator(ctx, state, request.URL, hardware)
		if err != nil {
			return http.Result[downloadResult]{}, &deviceAuthenticationError{"commerce_proof", err}
		}
		defer clear(next)
		if err = t.keychain.Set(deviceStateKey, next); err != nil {
			return http.Result[downloadResult]{}, err
		}
		if request.Headers == nil {
			request.Headers = map[string]string{}
		}
		for key, value := range proof {
			request.Headers[key] = value
		}
	}
	return t.downloadClient.Send(request)
}
