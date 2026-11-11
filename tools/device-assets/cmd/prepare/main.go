package main

import (
	"context"
	"fmt"
	"github.com/majd/ipatool/v2/internal/sap/assets"
	"net/http"
	"os"
	"time"
)

func main() {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Minute)
	defer cancel()
	base := http.DefaultTransport.(*http.Transport).Clone()
	base.Proxy = nil
	http.DefaultTransport = &appleOnlyTransport{next: base, limit: 2 << 30}
	bundle, err := assets.Load(ctx)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Printf("verified_modern_assets_bytes=%d\n", len(bundle.AppleMediaServices)+len(bundle.Commerce)+len(bundle.ADID)+len(bundle.CoreFP)+len(bundle.CoreFPICXS)+len(bundle.FairPlayD)+len(bundle.FairPlayKext))
}
