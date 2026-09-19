import os from "node:os";

// Tailscale hands every node an address out of the CGNAT block 100.64.0.0/10
// (RFC 6598). That block is the only interface Iris Link is ever allowed to
// bind: a LAN address or 0.0.0.0 would expose a terminal-capable agent to
// whatever else is on the coffee-shop Wi-Fi.
export function isTailscaleIPv4(address) {
  const parts = String(address || "").trim().split(".");
  if (parts.length !== 4) return false;
  const octets = parts.map((part) => (/^\d{1,3}$/.test(part) ? Number(part) : -1));
  if (octets.some((octet) => octet < 0 || octet > 255)) return false;
  return octets[0] === 100 && octets[1] >= 64 && octets[1] <= 127;
}

export function findTailscaleIPv4(networkInterfaces = os.networkInterfaces()) {
  for (const entries of Object.values(networkInterfaces || {})) {
    for (const entry of entries || []) {
      const family = entry?.family;
      const isIPv4 = family === "IPv4" || family === 4;
      if (!isIPv4 || entry?.internal) continue;
      if (isTailscaleIPv4(entry.address)) return entry.address;
    }
  }
  return null;
}
