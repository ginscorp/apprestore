package main

import (
	"bytes"
	"context"
	"encoding/csv"
	"encoding/json"
	"errors"
	"github.com/majd/ipatool/v2/internal/netguard"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
)

type catalogApp struct {
	ID       int64    `json:"id"`
	Name     string   `json:"name"`
	Aliases  []string `json:"aliases"`
	Sources  []string `json:"sources"`
	Category string   `json:"category"`
}
type catalogSource struct{ ID, Path, Format string }

var catalogSources = []catalogSource{
	{"back-to-iphone", "/n0hard/back-to-iphone/main/app/catalog.json", "json"},
	{"ipa-downloader", "/kda2495/IPA_Downloader/main/Files/AppsList.txt", "lines"},
	{"restoreipa-supplement", "/ToXiTy13/RestoreIPA/main/removed_ru_appstore_app_ids.csv", "csv"},
}

type sourceCache struct {
	ETag    string       `json:"etag"`
	Checked string       `json:"checked"`
	Apps    []catalogApp `json:"apps"`
}
type sourceStatus struct {
	Source string `json:"source"`
	Status string `json:"status"`
	Count  int    `json:"count"`
}
type catalogResult struct {
	Apps   []catalogApp   `json:"apps"`
	Status []sourceStatus `json:"status"`
}

func nameClean(s string) string {
	s = strings.TrimSpace(s)
	s = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) || unicode.In(r, unicode.Cf) {
			return -1
		}
		return r
	}, s)
	r := []rune(s)
	if len(r) > 240 {
		return string(r[:240])
	}
	return s
}
func parseCatalog(data []byte, kind, source string) ([]catalogApp, error) {
	if len(data) == 0 || len(data) > 2*1024*1024 {
		return nil, errors.New("invalid_size")
	}
	var rows []catalogApp
	add := func(id int64, name, category string) error {
		name = nameClean(name)
		if id < 1 || id > 99999999999 || name == "" {
			return errors.New("invalid_record")
		}
		rows = append(rows, catalogApp{ID: id, Name: name, Aliases: []string{name}, Sources: []string{source}, Category: nameClean(category)})
		return nil
	}
	switch kind {
	case "json":
		var payload struct {
			Apps []struct {
				ID       int64  `json:"id"`
				Name     string `json:"name"`
				Category string `json:"category"`
			} `json:"apps"`
		}
		if json.Unmarshal(data, &payload) != nil {
			return nil, errors.New("invalid_json")
		}
		for _, x := range payload.Apps {
			if err := add(x.ID, x.Name, x.Category); err != nil {
				return nil, err
			}
		}
	case "lines":
		for _, line := range strings.Split(string(bytes.TrimPrefix(data, []byte{239, 187, 191})), "\n") {
			line = strings.TrimSpace(line)
			if line == "" {
				continue
			}
			i := strings.LastIndex(line, ":")
			if i < 1 {
				return nil, errors.New("invalid_line")
			}
			id, err := strconv.ParseInt(strings.TrimSpace(line[i+1:]), 10, 64)
			if err != nil {
				return nil, err
			}
			if err = add(id, line[:i], ""); err != nil {
				return nil, err
			}
		}
	case "csv":
		r := csv.NewReader(bytes.NewReader(bytes.TrimPrefix(data, []byte{239, 187, 191})))
		records, err := r.ReadAll()
		if err != nil || len(records) < 2 {
			return nil, errors.New("invalid_csv")
		}
		idx := map[string]int{}
		for i, v := range records[0] {
			idx[v] = i
		}
		ii, iok := idx["app_id"]
		ni, nok := idx["name"]
		if !iok || !nok {
			return nil, errors.New("invalid_header")
		}
		for _, row := range records[1:] {
			id, err := strconv.ParseInt(row[ii], 10, 64)
			if err != nil {
				return nil, err
			}
			cat := ""
			if ci, ok := idx["category"]; ok {
				cat = row[ci]
			}
			if err = add(id, row[ni], cat); err != nil {
				return nil, err
			}
		}
	default:
		return nil, errors.New("unknown_format")
	}
	if len(rows) == 0 || len(rows) > 10000 {
		return nil, errors.New("invalid_count")
	}
	return rows, nil
}
func mergeCatalog(groups ...[]catalogApp) []catalogApp {
	m := map[int64]*catalogApp{}
	unique := func(xs []string, v string) []string {
		for _, x := range xs {
			if x == v {
				return xs
			}
		}
		return append(xs, v)
	}
	for _, g := range groups {
		for _, app := range g {
			cur, ok := m[app.ID]
			if !ok {
				x := app
				m[app.ID] = &x
				continue
			}
			cur.Aliases = unique(cur.Aliases, app.Name)
			for _, v := range app.Aliases {
				cur.Aliases = unique(cur.Aliases, v)
			}
			for _, v := range app.Sources {
				cur.Sources = unique(cur.Sources, v)
			}
			if cur.Category == "" {
				cur.Category = app.Category
			}
		}
	}
	out := make([]catalogApp, 0, len(m))
	for _, app := range m {
		sort.Strings(app.Sources)
		out = append(out, *app)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

type publicTransport struct{ base http.RoundTripper }

func (p publicTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	allowed := false
	for _, s := range catalogSources {
		if r.URL.Path == s.Path {
			allowed = true
		}
	}
	if !allowed || r.URL.Scheme != "https" || r.URL.Host != "raw.githubusercontent.com" || r.URL.RawQuery != "" || r.URL.User != nil || r.Method != "GET" {
		return nil, errors.New("public_destination_blocked")
	}
	// Fresh header set: this client cannot forward account tokens or cookies.
	clean := r.Clone(r.Context())
	clean.Header = make(http.Header)
	clean.Header.Set("User-Agent", "AppRestore/0.1 catalog")
	if tag := r.Header.Get("If-None-Match"); len(tag) < 256 {
		clean.Header.Set("If-None-Match", tag)
	}
	return p.base.RoundTrip(clean)
}
func loadCatalog(parent context.Context) (catalogResult, error) {
	root := os.Getenv("APPRESTORE_CATALOG_CACHE")
	seedRoot := os.Getenv("APPRESTORE_CATALOG_SEED")
	ctx, cancel := context.WithTimeout(parent, 8*time.Second)
	defer cancel()
	base := netguard.Base()
	base.Proxy = nil
	base.TLSHandshakeTimeout = 3 * time.Second
	defer base.CloseIdleConnections()
	client := &http.Client{Timeout: 3 * time.Second, Transport: publicTransport{base}, CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("redirect_blocked") }}
	groups := make([][]catalogApp, len(catalogSources))
	statuses := make([]sourceStatus, len(catalogSources))
	var wg sync.WaitGroup
	for i, src := range catalogSources {
		wg.Add(1)
		go func(i int, s catalogSource) {
			defer wg.Done()
			var previous sourceCache
			path := filepath.Join(root, s.ID+".json")
			if root != "" {
				if b, e := os.ReadFile(path); e == nil && len(b) <= 4*1024*1024 {
					_ = json.Unmarshal(b, &previous)
				}
			}
			if len(previous.Apps) == 0 {
				if b, e := os.ReadFile(filepath.Join(seedRoot, s.ID+".json")); e == nil {
					previous.Apps, _ = parseCatalog(b, "json", s.ID)
				}
			}
			groups[i] = previous.Apps
			statuses[i] = sourceStatus{s.ID, "cached", len(previous.Apps)}
			req, e := http.NewRequestWithContext(ctx, "GET", "https://raw.githubusercontent.com"+s.Path, nil)
			if e != nil {
				return
			}
			req.Header.Set("If-None-Match", previous.ETag)
			res, e := client.Do(req)
			if e != nil {
				statuses[i].Status = "offline"
				return
			}
			defer res.Body.Close()
			if res.StatusCode == 304 {
				statuses[i].Status = "unchanged"
				return
			}
			if res.StatusCode != 200 {
				statuses[i].Status = "source_unavailable"
				return
			}
			b, e := io.ReadAll(io.LimitReader(res.Body, 2*1024*1024+1))
			if e != nil {
				return
			}
			apps, e := parseCatalog(b, s.Format, s.ID)
			if e != nil {
				statuses[i].Status = "invalid_update_kept_previous"
				return
			}
			if len(previous.Apps) > 30 && len(apps)*100 < len(previous.Apps)*60 {
				statuses[i].Status = "large_removal_kept_previous"
				return
			}
			groups[i] = apps
			statuses[i] = sourceStatus{s.ID, "updated", len(apps)}
			if root != "" {
				cache := sourceCache{ETag: res.Header.Get("ETag"), Checked: time.Now().UTC().Format(time.RFC3339), Apps: apps}
				b, e := json.Marshal(cache)
				if e == nil && os.MkdirAll(root, 0700) == nil {
					f, e := os.CreateTemp(root, ".catalog-")
					if e == nil {
						tmp := f.Name()
						_, e = f.Write(b)
						if e == nil {
							e = f.Sync()
						}
						closeErr := f.Close()
						if e == nil && closeErr == nil {
							e = os.Rename(tmp, path)
						}
						if e != nil || closeErr != nil {
							_ = os.Remove(tmp)
							statuses[i].Status = "updated_cache_write_failed"
						}
					}
				}
			}
		}(i, src)
	}
	wg.Wait()
	apps := mergeCatalog(groups...)
	if len(apps) == 0 {
		return catalogResult{}, errors.New("empty_catalog")
	}
	return catalogResult{apps, statuses}, nil
}
