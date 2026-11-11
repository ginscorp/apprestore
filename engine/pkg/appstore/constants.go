package appstore

const (
	FailureTypeInvalidCredentials       = "-5000"
	FailureTypePasswordTokenExpired     = "2034"
	FailureTypeSignInRequired           = "2042"
	FailureTypeLicenseNotFound          = "9610"
	FailureTypeTemporarilyUnavailable   = "2059"
	FailureTypeLicenseAlreadyExists     = "5002"
	FailureTypeDeviceVerificationFailed = "1008"

	CustomerMessageBadLogin             = "MZFinance.BadLogin.Configurator_message"
	CustomerMessageAccountDisabled      = "Your account is disabled."
	CustomerMessageSubscriptionRequired = "Subscription Required"
	CustomerMessagePasswordChanged      = "Your password has changed."

	iTunesAPIDomain     = "itunes.apple.com"
	iTunesAPIPathSearch = "/search"
	iTunesAPIPathLookup = "/lookup"

	PrivateInitDomain = "init." + iTunesAPIDomain
	PrivateInitPath   = "/bag.xml"

	PrivateAppStoreAPIDomain       = "buy." + iTunesAPIDomain
	PrivateAppStoreNativeDomain    = "auth.itunes.apple.com"
	PrivateAppStoreNativePath      = "/auth/v1/native"
	storeAuthenticationUserAgent   = "Configurator/2.21 (Macintosh; OS X 27.0.1; 26A434) AppleWebKit/0625.2.5.11.6"
	PrivateAppStoreAPIPathAuth     = "/WebObjects/MZFinance.woa/wa/authenticate"
	PrivateAppStoreAPIPathPurchase = "/WebObjects/MZFinance.woa/wa/buyProduct"
	PrivateAppStoreAPIPathDownload = "/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct"

	PrivatePurchaseDAAPBaseURL = "https://pd.itunes.apple.com/WebObjects/MZPurchaseDaap.woa/purchase"

	HTTPHeaderStoreFront = "X-Set-Apple-Store-Front"
	HTTPHeaderPod        = "pod"

	PricingParameterAppStore    = "STDQ"
	PricingParameterAppleArcade = "GAME"
)
