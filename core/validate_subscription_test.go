package main

import "testing"

func TestSubscriptionValidationRejectsNonConfigResponses(t *testing.T) {
	for _, content := range []string{
		"<!doctype html><html><body>Maintenance</body></html>",
		"rules: [unknown-rule]\n",
		"{\"message\":\"subscription expired\"}",
		"# maintenance\n",
	} {
		if message := handleValidateConfig(&ValidateConfigParams{Data: content}); message == "" {
			t.Errorf("accepted non-config response %q", content)
		}
	}
	for _, content := range []string{"rules: ['MATCH,DIRECT']", "mode: direct\nvendor-option: true"} {
		if message := handleValidateConfig(&ValidateConfigParams{Data: content}); message != "" {
			t.Errorf("rejected supported profile %q: %s", content, message)
		}
	}
}
