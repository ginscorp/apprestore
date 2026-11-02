// AppRestore helper uses one private pipe and one account per process. No HTTP listener.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/cookiejar"
	"os"
	"os/signal"
	"path/filepath"
	"runtime/debug"
	"strings"
	"syscall"
	"time"

	"github.com/majd/ipatool/v2/internal/netguard"
	"github.com/majd/ipatool/v2/internal/sap/assets"
	"github.com/majd/ipatool/v2/internal/sap/unicorn"
	"github.com/majd/ipatool/v2/pkg/appstore"
	"github.com/majd/ipatool/v2/pkg/util/machine"
	"github.com/majd/ipatool/v2/pkg/util/operatingsystem"
	"github.com/rs/zerolog"
)

type request struct {
	Action    string `json:"action"`
	Email     string `json:"email"`
	Password  string `json:"password"`
	Code      string `json:"code"`
	AppID     int64  `json:"app_id"`
	Confirmed bool   `json:"confirmed"`
}
type reply struct {
	OK         bool             `json:"ok"`
	Error      string           `json:"error,omitempty"`
	Data       any              `json:"data,omitempty"`
	Diagnostic *checkDiagnostic `json:"diagnostic,omitempty"`
}
type session struct {
	store       *memoryStore
	api         appstore.AppStore
	account     appstore.Account
	directory   string
	packagePath string
}

func main() {
	syscall.Umask(0077)
	_ = syscall.Setrlimit(syscall.RLIMIT_CORE, &syscall.Rlimit{Cur: 0, Max: 0})
	zerolog.SetGlobalLevel(zerolog.Disabled)
	debug.SetTraceback("none")
	if len(os.Args) == 2 && os.Args[1] == "--prepare" {
		os.Setenv("APPRESTORE_PREPARE", "1")
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Minute)
		defer cancel()
		_, err := assets.Load(ctx)
		if err == nil {
			_, err = assets.LoadStoreAgent(ctx)
		}
		if err == nil {
			err = unicorn.Prepare(ctx)
		}
		if err != nil {
			io.WriteString(os.Stderr, err.Error()+"\n")
			os.Exit(1)
		}
		io.WriteString(os.Stdout, "runtime_ready\n")
		return
	}
	if len(os.Args) != 1 {
		return
	}
	// Every normal runtime client, including redirects and SAP clients, uses this guard.
	base := http.DefaultTransport.(*http.Transport).Clone()
	base.Proxy = nil
	http.DefaultTransport = netguard.Transport{Next: base}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	requests := make(chan []byte)
	go func() {
		defer close(requests)
		defer cancel()
		s := bufio.NewScanner(os.Stdin)
		s.Buffer(make([]byte, 4096), 65536)
		for s.Scan() {
			b := append([]byte(nil), s.Bytes()...)
			select {
			case requests <- b:
			case <-ctx.Done():
				clear(b)
				return
			}
		}
	}()
	s := &session{}
	defer s.close()
	enc := json.NewEncoder(os.Stdout)
	for {
		select {
		case <-ctx.Done():
			return
		case line, ok := <-requests:
			if !ok {
				return
			}
			var q request
			if json.Unmarshal(line, &q) != nil {
				clear(line)
				_ = enc.Encode(reply{Error: "invalid_request"})
				continue
			}
			clear(line)
			r := s.handle(ctx, q)
			q.Password = ""
			q.Code = ""
			_ = enc.Encode(r)
			if q.Action == "close" {
				return
			}
		}
	}
}
func (s *session) close() error {
	if s.store != nil {
		s.store.Close()
	}
	s.account = appstore.Account{}
	s.api = nil
	if s.directory != "" {
		if err := os.RemoveAll(s.directory); err != nil {
			return err
		}
		if _, err := os.Stat(s.directory); !errors.Is(err, os.ErrNotExist) {
			return errors.New("cleanup_failed")
		}
	}
	s.directory = ""
	s.packagePath = ""
	return nil
}
func (s *session) handle(ctx context.Context, q request) (r reply) {
	defer func() {
		if recover() != nil {
			s.close()
			r = reply{Error: "internal_error"}
		}
	}()
	switch q.Action {
	case "runtime_check":
		if _, err := assets.Load(ctx); err != nil {
			return reply{Error: "runtime_missing"}
		}
		if _, err := assets.LoadStoreAgent(ctx); err != nil {
			return reply{Error: "runtime_missing"}
		}
		emulator, err := unicorn.New(ctx)
		if err != nil {
			return reply{Error: "runtime_missing"}
		}
		_ = emulator.Close()
		return reply{OK: true, Data: map[string]bool{"verified_assets": true, "emulator_loaded": true}}
	case "ping":
		return reply{OK: true, Data: map[string]any{"version": "0.8.2", "credentials": "memory_only", "keychain": false}}
	case "catalog":
		if s.api != nil {
			return reply{Error: "close_session_first"}
		}
		data, err := loadCatalog(ctx)
		if err != nil {
			return reply{Error: "catalog_unavailable"}
		}
		return reply{OK: true, Data: data}
	case "close":
		if err := s.close(); err != nil {
			return reply{Error: "cleanup_failed"}
		}
		return reply{OK: true}
	case "login":
		if s.api != nil {
			return reply{Error: "close_session_first"}
		}
		if len(q.Email) > 320 || len(q.Password) > 4096 || q.Email == "" || q.Password == "" || len(q.Code) > 8 {
			return reply{Error: "invalid_credentials"}
		}
		mem := newMemory()
		jar, _ := cookiejar.New(nil)
		system := operatingsystem.New()
		api := appstore.NewAppStore(appstore.Args{Keychain: mem, CookieJar: memoryCookies{jar}, OperatingSystem: system, Machine: machine.New(machine.Args{OS: system})})
		out, err := api.Login(appstore.LoginInput{Email: q.Email, Password: q.Password, AuthCode: q.Code})
		q.Password = ""
		q.Code = ""
		if err != nil {
			mem.Close()
			return reply{Error: errorCode(err)}
		}
		out.Account.Password = ""
		s.account = out.Account
		s.store = mem
		s.api = api
		return reply{OK: true, Data: map[string]string{"email": out.Account.Email}}
	}
	if s.api == nil {
		return reply{Error: "not_authenticated"}
	}
	if q.AppID < 1 || q.AppID > 99999999999 {
		return reply{Error: "invalid_app_id"}
	}
	app := appstore.App{ID: q.AppID}
	switch q.Action {
	case "check":
		netguard.BeginTrace()
		stage := "list_versions"
		var checkErr error
		defer func() {
			r.Diagnostic = makeCheckDiagnostic(q.AppID, stage, r.Error, netguard.EndTrace())
			r.Diagnostic.ResponseSummary = summarizeCheckError(checkErr)
		}()
		out, err := s.api.ListVersions(appstore.ListVersionsInput{Context: ctx, Account: s.account, App: app, Platform: appstore.PlatformIPhone})
		if err != nil {
			checkErr = err
			return reply{Error: errorCode(err)}
		}
		stage = "version_metadata"
		meta, metaErr := s.api.GetVersionMetadata(appstore.GetVersionMetadataInput{Context: ctx, Account: s.account, App: app, VersionID: out.LatestExternalVersionID, Platform: appstore.PlatformIPhone})
		stage = "complete"
		if metaErr != nil {
			checkErr = metaErr
			stage = "licensed_metadata_unavailable"
		}
		return reply{OK: true, Data: map[string]any{"licensed": true, "version": meta.DisplayVersion, "version_count": len(out.ExternalVersionIdentifiers)}}
	case "acquire":
		if !q.Confirmed {
			return reply{Error: "confirmation_required"}
		}
		found, err := s.api.Lookup(appstore.LookupInput{Account: s.account, AppID: q.AppID, Platform: appstore.PlatformIPhone})
		if err != nil {
			return reply{Error: errorCode(err)}
		}
		if found.App.ID != q.AppID || found.App.Price != 0 {
			return reply{Error: "free_apps_only"}
		}
		if err = s.api.Purchase(appstore.PurchaseInput{Account: s.account, App: found.App, Platform: appstore.PlatformIPhone}); err != nil && !errors.Is(err, appstore.ErrLicenseAlreadyExists) {
			return reply{Error: errorCode(err)}
		}
		return reply{OK: true}
	case "download":
		if !q.Confirmed {
			return reply{Error: "confirmation_required"}
		}
		if s.directory != "" {
			// A new explicit download replaces only our previous temporary IPA.
			// The authenticated account, tokens and cookies remain in this process.
			if err := os.RemoveAll(s.directory); err != nil {
				return reply{Error: "cleanup_failed"}
			}
			if _, err := os.Stat(s.directory); !errors.Is(err, os.ErrNotExist) {
				return reply{Error: "cleanup_failed"}
			}
			s.directory = ""
			s.packagePath = ""
		}
		var err error
		s.directory, err = os.MkdirTemp("", "apprestore-session-")
		if err != nil {
			return reply{Error: "disk_error"}
		}
		destination := filepath.Join(s.directory, "application.ipa")
		operation, cancelOperation := context.WithTimeout(ctx, 20*time.Minute)
		defer cancelOperation()
		var rawCache *appstore.RawPackageCache
		if library := os.Getenv("APPRESTORE_LIBRARY"); library != "" {
			rawCache = &appstore.RawPackageCache{Root: filepath.Join(library, "packages")}
		}
		out, err := s.api.Download(appstore.DownloadInput{Context: operation, Account: s.account, App: app, OutputPath: destination, Platform: appstore.PlatformIPhone, RawCache: rawCache})
		if err != nil {
			_ = os.RemoveAll(s.directory)
			s.directory = ""
			return reply{Error: errorCode(err)}
		}
		if out.DestinationPath != destination {
			return reply{Error: "unexpected_path"}
		}
		before, err := packageState(destination, q.AppID, false)
		if err != nil {
			return reply{Error: "package_preparation_failed"}
		}
		// Download returns the Apple SINF separately. The upstream CLI performs this
		// mandatory second step; our library integration must perform it as well.
		if err = s.api.ReplicateSinf(appstore.ReplicateSinfInput{Sinfs: out.Sinfs, PackagePath: destination}); err != nil {
			return reply{Error: "package_preparation_failed"}
		}
		after, err := packageState(destination, q.AppID, true)
		if err != nil || before != after {
			return reply{Error: "license_data_missing"}
		}
		s.packagePath = destination
		info, err := os.Stat(destination)
		if err != nil {
			return reply{Error: "disk_error"}
		}
		return reply{OK: true, Data: map[string]any{"path": destination, "bytes": info.Size(), "app_id": q.AppID, "license_ready": true, "cache_used": out.CacheUsed, "cache_stored": out.CacheStored}}
	}
	return reply{Error: "unsupported_action"}
}
func errorCode(err error) string {
	if code := safeAppleFailure(err); code != "" {
		return code
	}
	switch {
	case errors.Is(err, appstore.ErrPackageIntegrity):
		return "package_integrity_failed"
	case errors.Is(err, appstore.ErrPackageLimit):
		return "package_size_limit"
	case errors.Is(err, appstore.ErrAuthCodeRequired):
		return "two_factor_required"
	case errors.Is(err, appstore.ErrLicenseRequired):
		return "license_required"
	case errors.Is(err, appstore.ErrPasswordTokenExpired):
		return "session_expired"
	case errors.Is(err, appstore.ErrAppNotFound):
		return "app_not_available"
	case errors.Is(err, context.Canceled):
		return "cancelled"
	case strings.Contains(err.Error(), "assets_missing") || strings.Contains(err.Error(), "runtime_missing"):
		return "runtime_missing"
	case strings.Contains(err.Error(), "destination_blocked"):
		return "destination_blocked"
	default:
		return "apple_request_failed"
	}
}
