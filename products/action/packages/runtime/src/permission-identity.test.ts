import assert from "node:assert/strict";
import { describe, test } from "node:test";

import {
  diagnosePermissions,
  hostAppPath,
  owningActionApp,
  parseCodesign,
  type ActionBundleSigning,
} from "./permission-identity.js";

const release: ActionBundleSigning = {
  path: "/Applications/Action.app",
  signer: "developer-id",
  authority: "Developer ID Application: Arach Tchoupani (2U83JFPW66)",
  teamId: "2U83JFPW66",
  requirement: 'identifier "dev.lattices.Action" and certificate leaf[subject.OU] = "2U83JFPW66"',
};
const devBuild: ActionBundleSigning = {
  path: "/Users/art/dev/lattices/products/action/native/dist/Action.app",
  signer: "apple-development",
  authority: "Apple Development: Arach Tchoupani (D58PF38LQK)",
  teamId: "2U83JFPW66",
  requirement: 'identifier "dev.lattices.Action" and certificate leaf[subject.CN] = "Apple Development: Arach Tchoupani (D58PF38LQK)"',
};
const releaseCheckout: ActionBundleSigning = {
  ...release,
  path: "/Users/art/dev/lattices-demo-stage/products/action/native/dist/Action.app",
};

describe("permission identity", () => {
  test("parses codesign output into a signer", () => {
    const signing = parseCodesign(
      "/Applications/Action.app",
      [
        "Executable=/Applications/Action.app/Contents/MacOS/Action",
        "Identifier=dev.lattices.Action",
        "Authority=Developer ID Application: Arach Tchoupani (2U83JFPW66)",
        "Authority=Developer ID Certification Authority",
        "TeamIdentifier=2U83JFPW66",
      ].join("\n"),
      `designated => ${release.requirement}\n`,
    );
    assert.equal(signing.signer, "developer-id");
    assert.equal(signing.teamId, "2U83JFPW66");
    assert.equal(signing.requirement, release.requirement);

    const adhoc = parseCodesign("/tmp/Action.app", "Signature=adhoc\nTeamIdentifier=not set", "");
    assert.equal(adhoc.signer, "ad-hoc");
    assert.equal(adhoc.teamId, undefined);
  });

  test("maps the helper agent back to the app that owns its grant", () => {
    assert.equal(
      owningActionApp("/Applications/Action.app/Contents/Helpers/ActionAgent.app"),
      "/Applications/Action.app",
    );
    assert.equal(owningActionApp("/Applications/Action.app"), "/Applications/Action.app");
  });

  test("finds the dist copy run-app-host.sh launches", () => {
    assert.equal(
      hostAppPath("/repo/products/action/native/engine/scripts/run-app-host.sh"),
      "/repo/products/action/native/dist/Action.app",
    );
  });

  test("reports granted from the agent even when a stale dist copy disagrees", () => {
    const report = diagnosePermissions({
      agent: { accessibility: "granted", screenRecording: "granted", app: release },
      host: { accessibility: "denied", screenRecording: "denied", app: devBuild },
      copies: [release, devBuild],
    });
    assert.equal(report.verdict, "granted");
    assert.equal(report.source, "agent");
    assert.match(report.warnings.join("\n"), /signed differently/);
  });

  test("names a split identity instead of a bare denied", () => {
    const report = diagnosePermissions({
      agent: { accessibility: "denied", screenRecording: "granted", app: release },
      host: { accessibility: "denied", screenRecording: "granted", app: release },
      copies: [release, devBuild],
    });
    assert.equal(report.verdict, "identity-split");
    assert.equal(report.grantTarget, "/Applications/Action.app");
    assert.match(report.fix ?? "", /Apple Development/);
    assert.match(report.fix ?? "", /Accessibility/);
  });

  test("tells a stale agent to restart when a fresh launch sees the grant", () => {
    const report = diagnosePermissions({
      agent: { accessibility: "granted", screenRecording: "denied", app: release },
      host: { accessibility: "granted", screenRecording: "granted", app: releaseCheckout },
      copies: [release, releaseCheckout],
    });
    assert.equal(report.verdict, "stale-agent");
    assert.match(report.fix ?? "", /Screen Recording/);
  });

  test("asks for a plain grant when every copy shares one signature", () => {
    const report = diagnosePermissions({
      agent: { accessibility: "denied", screenRecording: "denied", app: release },
      host: { accessibility: "denied", screenRecording: "denied", app: releaseCheckout },
      copies: [release, releaseCheckout],
    });
    assert.equal(report.verdict, "needs-grant");
    assert.deepEqual(report.warnings, []);
  });

  test("falls back to the host probe when the agent does not answer", () => {
    const report = diagnosePermissions({
      agentError: "Action agent is unavailable",
      host: { accessibility: "granted", screenRecording: "granted", app: release },
      copies: [release],
    });
    assert.equal(report.verdict, "granted");
    assert.equal(report.source, "host");
    assert.match(report.warnings.join("\n"), /did not answer/);
  });
});
