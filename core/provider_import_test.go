package main

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/metacubex/mihomo/component/resource"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	R "github.com/metacubex/mihomo/rules/provider"
)

func TestProviderFileImportValidatesBeforeReplacingCache(t *testing.T) {
	previous := constant.Path.HomeDir()
	dir := t.TempDir()
	constant.SetHomeDir(dir)
	t.Cleanup(func() { constant.SetHomeDir(previous) })

	var mrs bytes.Buffer
	if err := R.ConvertToMrs([]byte("example.test\n"), P.Domain, P.TextRule, &mrs); err != nil {
		t.Fatal(err)
	}
	const staging = ".provider-import-test"
	if err := os.WriteFile(filepath.Join(dir, staging), mrs.Bytes(), 0600); err != nil {
		t.Fatal(err)
	}
	data, err := readProviderImport(staging, fmt.Sprintf("%x", sha256.Sum256(mrs.Bytes())))
	if err != nil || !bytes.Equal(data, mrs.Bytes()) {
		t.Fatalf("staged bytes changed: %v", err)
	}
	if _, err := readProviderImport(staging, "changed"); err == nil {
		t.Fatal("accepted changed import")
	}
	path := filepath.Join(dir, "domains.mrs")
	rules := R.NewRuleSetProvider("domains", P.Domain, P.MrsRule, 0, resource.NewFileVehicle(path), nil, nil, nil)
	if err := sideUpdateExternalProvider(rules, data); err != nil || rules.Count() != 1 {
		t.Fatalf("import MRS: %v, count=%d", err, rules.Count())
	}
	cfg, err := config.Parse([]byte("proxy-providers:\n  nodes: {type: file, path: nodes.yaml}\n"))
	if err != nil {
		t.Fatal(err)
	}
	nodes := cfg.Providers["nodes"]
	nodeData := []byte("proxies:\n  - {name: Local, type: direct}\n")
	if err := sideUpdateExternalProvider(nodes, nodeData); err != nil {
		t.Fatalf("import nodes: %v", err)
	}
	for _, test := range []struct {
		provider P.Provider
		path     string
		want     []byte
	}{{rules, path, data}, {nodes, filepath.Join(dir, "nodes.yaml"), nodeData}} {
		if err := sideUpdateExternalProvider(test.provider, []byte("[")); err == nil {
			t.Fatalf("%s accepted invalid data", test.provider.Name())
		}
		saved, err := os.ReadFile(test.path)
		if err != nil || !bytes.Equal(saved, test.want) {
			t.Fatalf("%s lost previous cache: %v", test.provider.Name(), err)
		}
	}
}
