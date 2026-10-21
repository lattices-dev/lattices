import { join } from "node:path";
import { PairingApprovals } from "../../host-linux/src/bridge/approval.ts";
import { BridgeSecurity, HEADERS, loadOrCreateBridgeKey, type TrustedDevice } from "../../host-linux/src/bridge/security.ts";
import type { Identity } from "../../host-linux/src/auth.ts";
import { privateDirectory } from "../../host-linux/src/private-ipc.ts";
import { requestedGrants, validGrant } from "./policy.ts";

export class GatewayPairing {
  readonly approvals: PairingApprovals;
  readonly security: BridgeSecurity;
  constructor(name: string, stateDir: string, approvals = new PairingApprovals(120_000, false, "Lattices gateway")) {
    privateDirectory(stateDir);
    this.approvals = approvals;
    this.security = new BridgeSecurity({
      bridgeName: name,
      privateKey: loadOrCreateBridgeKey(join(stateDir, "gateway-key.json")),
      devicesPath: join(stateDir, "gateway-clients.json"),
      approve: (request, kind, additions) => {
        if (this.approvals.list().length >= 16) return Promise.resolve(false);
        return this.approvals.request(request, kind, additions);
      },
      grant: requested => (requested ?? []).filter(validGrant),
    });
  }
  authenticate(headers: Headers): TrustedDevice | null {
    if (!headers.has(HEADERS.deviceID)) return null;
    return this.security.authorize("GET", "/", headers, Buffer.alloc(0)).device;
  }
  async pair(params: Record<string, unknown>, identity: Identity) {
    for (const key of ["clientID", "clientName", "publicKey", "platform"]) {
      if (typeof params[key] !== "string" || !(params[key] as string).trim() || (params[key] as string).length > 128) throw new Error(`Invalid ${key}`);
    }
    const result = await this.security.handlePairing({
      deviceID: params.clientID as string, deviceName: params.clientName as string,
      devicePublicKey: params.publicKey as string, platform: params.platform as string,
      requestedCapabilities: requestedGrants(params), node: identity.node,
    });
    return { disposition: result.disposition, host: result.bridgeName, hostPublicKey: result.bridgePublicKey, hostFingerprint: result.bridgeFingerprint,
      scope: params.scope ?? "read", grants: result.grantedCapabilities, detail: result.detail };
  }
  client(id: string): TrustedDevice | undefined { return this.security.trustedDevices().find(c => c.id === id); }
  list() { return { fingerprint: this.security.fingerprint, clients: this.security.trustedDevices().map(({ publicKey: _key, ...client }) => client), pending: this.approvals.list() }; }
  stop() { for (const pending of this.approvals.list()) this.approvals.decide(pending.deviceID, false); }
}
