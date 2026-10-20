package main

import (
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
)

func TestInvalidConfigPreservesLoadedConfig(t *testing.T) {
	previousHome := constant.Path.HomeDir()
	previousConfig := currentConfig
	previousTestURL := constant.DefaultTestURL
	previousNames := config.GetProxyNameList()
	t.Cleanup(func() {
		constant.SetHomeDir(previousHome)
		currentConfig = previousConfig
		constant.DefaultTestURL = previousTestURL
		config.SetProxyNameList(previousNames)
	})

	home := t.TempDir()
	constant.SetHomeDir(home)
	loaded := &config.Config{}
	currentConfig = loaded
	for _, source := range []string{
		"proxies: [invalid yaml",
		"proxy-groups:\n  - name: new-group\n    type: select\n    proxies: [DIRECT]\nrules: [INVALID-RULE]\n",
	} {
		config.SetProxyNameList([]string{"existing-group"})
		if err := os.WriteFile(filepath.Join(home, "config.yaml"), []byte(source), 0600); err != nil {
			t.Fatal(err)
		}
		if err := applyConfig(defaultSetupParams()); err == nil {
			t.Fatal("invalid config was accepted")
		}
		if currentConfig != loaded {
			t.Fatal("a failed refresh replaced the loaded config")
		}
		if constant.DefaultTestURL != previousTestURL {
			t.Fatal("a failed refresh changed the active test URL")
		}
		if !slices.Equal(config.GetProxyNameList(), []string{"existing-group"}) {
			t.Fatal("a failed refresh changed the active group enumeration")
		}
	}
}

func TestValidateMissingAndEmptyConfig(t *testing.T) {
	path := filepath.Join(t.TempDir(), "subscription.yaml")
	if message := handleValidateConfig(path); message == "" {
		t.Fatal("a missing subscription was accepted")
	}
	if err := os.WriteFile(path, nil, 0600); err != nil {
		t.Fatal(err)
	}
	if message := handleValidateConfig(path); message == "" {
		t.Fatal("an empty subscription was accepted")
	}
}
