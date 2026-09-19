import test from "node:test";
import assert from "node:assert/strict";
import { findTailscaleIPv4, isTailscaleIPv4 } from "../electron/tailscaleAddress.mjs";

test("recognizes only the 100.64.0.0/10 CGNAT range", () => {
  assert.equal(isTailscaleIPv4("100.64.0.1"), true);
  assert.equal(isTailscaleIPv4("100.101.102.103"), true);
  assert.equal(isTailscaleIPv4("100.127.255.255"), true);
  assert.equal(isTailscaleIPv4("100.63.255.255"), false);
  assert.equal(isTailscaleIPv4("100.128.0.1"), false);
  assert.equal(isTailscaleIPv4("192.168.1.20"), false);
  assert.equal(isTailscaleIPv4("10.0.0.5"), false);
  assert.equal(isTailscaleIPv4("0.0.0.0"), false);
  assert.equal(isTailscaleIPv4("fd7a:115c::1"), false);
  assert.equal(isTailscaleIPv4(""), false);
  assert.equal(isTailscaleIPv4("100.64.0"), false);
  assert.equal(isTailscaleIPv4("100.64.0.999"), false);
});

test("finds the tailscale address and ignores LAN, loopback and IPv6", () => {
  const interfaces = {
    lo0: [{ family: "IPv4", address: "127.0.0.1", internal: true }],
    en0: [
      { family: "IPv4", address: "192.168.1.20", internal: false },
      { family: "IPv6", address: "fe80::1", internal: false },
    ],
    utun4: [
      { family: "IPv6", address: "fd7a:115c:a1e0::1", internal: false },
      { family: "IPv4", address: "100.101.102.103", internal: false },
    ],
  };
  assert.equal(findTailscaleIPv4(interfaces), "100.101.102.103");
});

test("returns null when no tailscale interface exists", () => {
  assert.equal(
    findTailscaleIPv4({
      en0: [{ family: "IPv4", address: "192.168.1.20", internal: false }],
    }),
    null,
  );
  assert.equal(findTailscaleIPv4({}), null);
  assert.equal(findTailscaleIPv4(null), null);
});

test("accepts the numeric family form Node may report", () => {
  assert.equal(
    findTailscaleIPv4({ utun0: [{ family: 4, address: "100.70.1.2", internal: false }] }),
    "100.70.1.2",
  );
});
