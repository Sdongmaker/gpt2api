package settings

import "testing"

func TestSiteNameFallsBackToMaxAPI(t *testing.T) {
	svc := NewService(nil)

	if got := svc.SiteName(); got != "MAX API" {
		t.Fatalf("SiteName() = %q, want %q", got, "MAX API")
	}
}

func TestPublicSnapshotUsesMaxAPIDefaultSiteName(t *testing.T) {
	svc := NewService(nil)

	public := svc.PublicSnapshot()
	if got := public[SiteName]; got != "MAX API" {
		t.Fatalf("PublicSnapshot()[%q] = %q, want %q", SiteName, got, "MAX API")
	}
}
