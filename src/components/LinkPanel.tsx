import { useEffect, useRef, useState } from "react";
import QRCode from "qrcode";
import { Loader2, QrCode, RefreshCw, Smartphone, Trash2 } from "lucide-react";
import { ThemedSelect } from "./ThemedSelect";

const STATUS_POLL_MS = 5000;
const DEVICE_POLL_MS = 3000;

type OfferState = { payload: string; code: string; expiresAt: number } | { expired: true } | null;

// Human-readable explanation for each `reason` the backend can report. Keep in
// sync with electron/main.mjs's startIrisLink()/irisLinkStatus().
function statusMessage(status: IrisLinkStatus | null): string {
  if (!status) return "Checking status…";
  if (status.listening && status.host && status.port) {
    return `Listening on ${status.host}:${status.port}`;
  }
  if (!status.enabled) return "Not enabled.";
  switch (status.reason) {
    case "no_tailscale_address":
      return "Tailscale isn't running or connected on this Mac. Start Tailscale, then reopen Settings.";
    case "listen_failed":
      return "Could not start — the port may already be in use.";
    case "stopped":
      return "Not running.";
    case "disabled":
      return "Not enabled.";
    default:
      return status.reason ? `Not running (${status.reason}).` : "Not running.";
  }
}

function relativeTime(ms: number): string {
  const diff = Date.now() - ms;
  if (diff < 30_000) return "just now";
  if (diff < 60_000) return `${Math.floor(diff / 1000)}s ago`;
  if (diff < 3_600_000) return `${Math.floor(diff / 60_000)}m ago`;
  if (diff < 86_400_000) return `${Math.floor(diff / 3_600_000)}h ago`;
  return `${Math.floor(diff / 86_400_000)}d ago`;
}

function formatCountdown(ms: number): string {
  const total = Math.max(0, Math.ceil(ms / 1000));
  const m = Math.floor(total / 60);
  const s = total % 60;
  return `${m}:${String(s).padStart(2, "0")}`;
}

export default function LinkPanel({
  enabled,
  savedEnabled,
  onChangeEnabled,
}: {
  enabled: string;
  savedEnabled: boolean;
  onChangeEnabled: (value: string) => void;
}) {
  const [status, setStatus] = useState<IrisLinkStatus | null>(null);
  const [devices, setDevices] = useState<IrisLinkDevice[]>([]);
  const [offer, setOffer] = useState<OfferState>(null);
  const [offerError, setOfferError] = useState<string | null>(null);
  const [offerBusy, setOfferBusy] = useState(false);
  const [qrSvg, setQrSvg] = useState<string | null>(null);
  const [now, setNow] = useState(() => Date.now());
  const [confirmRevoke, setConfirmRevoke] = useState<string | null>(null);
  const [revokeBusy, setRevokeBusy] = useState<string | null>(null);

  const deviceCountAtOfferStart = useRef(0);
  const mounted = useRef(true);

  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);

  const refreshStatus = async () => {
    try {
      const result = await window.iris.getLinkStatus();
      if (mounted.current) setStatus(result);
    } catch {
      // Leave last-known status on a transient IPC error.
    }
  };

  const refreshDevices = async () => {
    try {
      const result = await window.iris.listLinkDevices();
      if (mounted.current) setDevices(result);
      return result;
    } catch {
      return devices;
    }
  };

  // Live status line, polled the whole time Settings is open.
  useEffect(() => {
    refreshStatus();
    refreshDevices();
    const id = window.setInterval(refreshStatus, STATUS_POLL_MS);
    return () => window.clearInterval(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Countdown ticker while an offer is showing.
  useEffect(() => {
    if (!offer || "expired" in offer) return;
    const id = window.setInterval(() => setNow(Date.now()), 250);
    return () => window.clearInterval(id);
  }, [offer]);

  // Once we hit zero, clear the QR immediately — never leave an expired one on screen.
  useEffect(() => {
    if (!offer || "expired" in offer) return;
    if (now >= offer.expiresAt) {
      setOffer({ expired: true });
      setQrSvg(null);
    }
  }, [now, offer]);

  // Poll the device list while a pairing offer is active so a newly paired
  // phone appears on its own, then dismiss the QR.
  useEffect(() => {
    if (!offer || "expired" in offer) return;
    const id = window.setInterval(async () => {
      const list = await refreshDevices();
      if (list.length > deviceCountAtOfferStart.current) {
        setOffer(null);
        setQrSvg(null);
      }
    }, DEVICE_POLL_MS);
    return () => window.clearInterval(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [offer]);

  // Hide/clear the QR on unmount (Settings closed).
  useEffect(() => {
    return () => {
      setQrSvg(null);
    };
  }, []);

  async function pairDevice() {
    setOfferBusy(true);
    setOfferError(null);
    setQrSvg(null);
    try {
      const result = await window.iris.createLinkOffer();
      if (!result.ok) {
        setOffer(null);
        setOfferError(result.error || "Could not create a pairing offer.");
        return;
      }
      deviceCountAtOfferStart.current = devices.length;
      setOffer({ payload: result.payload, code: result.code, expiresAt: result.expiresAt });
      setNow(Date.now());
      // Rendered locally only — the secret-bearing payload never leaves this
      // process or touches the network.
      const svg = await QRCode.toString(result.payload, {
        type: "svg",
        margin: 1,
        width: 200,
        color: { dark: "#0b111c", light: "#ffffff" },
      });
      if (mounted.current) setQrSvg(svg);
    } catch (error) {
      setOffer(null);
      setOfferError(error instanceof Error ? error.message : "Could not create a pairing offer.");
    } finally {
      if (mounted.current) setOfferBusy(false);
    }
  }

  async function revokeDevice(id: string) {
    setRevokeBusy(id);
    try {
      await window.iris.revokeLinkDevice(id);
      await refreshDevices();
    } finally {
      if (mounted.current) {
        setRevokeBusy(null);
        setConfirmRevoke(null);
      }
    }
  }

  const listening = Boolean(status?.listening);
  const showRestartNote = enabled !== (savedEnabled ? "true" : "false");
  const offerActive = offer && !("expired" in offer);
  const remainingMs = offerActive ? Math.max(0, (offer as { expiresAt: number }).expiresAt - now) : 0;

  return (
    <section className="setup-section">
      <h3>Phone &amp; devices</h3>
      <p className="setup-hint">
        Pair your iPhone with Iris over your Tailscale network so it can hear you and relay Hermes work from
        anywhere your tailnet reaches.
      </p>

      <label className="setup-field">
        <span>Iris Link</span>
        <ThemedSelect
          ariaLabel="Iris Link"
          value={enabled}
          options={[
            { value: "true", label: "On — allow pairing a phone" },
            { value: "false", label: "Off" },
          ]}
          onChange={onChangeEnabled}
        />
        <small className="setup-note">
          Runs a small server bound only to this Mac's Tailscale address — never your LAN or the open internet.
          {showRestartNote ? " Takes effect after you restart Iris." : ""}
        </small>
      </label>

      <div className="link-status">
        <span className={`link-status-dot ${listening ? "on" : "off"}`} />
        <span>{statusMessage(status)}</span>
      </div>

      <div className="setup-actions">
        <button
          className="setup-btn"
          onClick={pairDevice}
          disabled={!listening || offerBusy}
          title={listening ? "Generate a QR code to pair a phone" : "Iris Link isn't listening"}
        >
          {offerBusy ? <Loader2 size={14} className="spin" /> : <QrCode size={14} />}
          Pair a device
        </button>
        {offerError ? <span className="setup-result err">{offerError}</span> : null}
      </div>

      {offerActive ? (
        <div className="link-pair">
          <div className="link-qr-tile">
            {qrSvg ? (
              <div className="link-qr" dangerouslySetInnerHTML={{ __html: qrSvg }} />
            ) : (
              <Loader2 size={24} className="spin" />
            )}
          </div>
          <div className="link-pair-info">
            <div className="link-code">{(offer as { code: string }).code}</div>
            <p className="setup-note">Confirm this code matches what your phone shows, then approve on the phone.</p>
            <div className="link-countdown">Expires in {formatCountdown(remainingMs)}</div>
          </div>
        </div>
      ) : offer && "expired" in offer ? (
        <div className="link-pair expired">
          <p className="setup-note">That code expired.</p>
          <button className="setup-btn ghost" onClick={pairDevice} disabled={!listening || offerBusy}>
            <RefreshCw size={14} />
            New code
          </button>
        </div>
      ) : null}

      <div className="link-devices">
        {devices.length === 0 ? (
          <p className="link-empty">No devices paired yet.</p>
        ) : (
          devices.map((device) => (
            <div className="link-device" key={device.id}>
              <span className="link-device-icon">
                <Smartphone size={16} />
              </span>
              <div className="link-device-info">
                <span className="link-device-name">{device.name}</span>
                <span className="link-device-meta">
                  Paired {new Date(device.createdAt).toLocaleDateString()} · Last active{" "}
                  {device.lastSeenAt && device.lastSeenAt > device.createdAt
                    ? relativeTime(device.lastSeenAt)
                    : "never"}
                </span>
              </div>
              {confirmRevoke === device.id ? (
                <div className="link-confirm">
                  <span>Revoke?</span>
                  <button
                    className="setup-btn ghost"
                    onClick={() => revokeDevice(device.id)}
                    disabled={revokeBusy === device.id}
                  >
                    {revokeBusy === device.id ? <Loader2 size={14} className="spin" /> : "Confirm"}
                  </button>
                  <button className="setup-btn ghost" onClick={() => setConfirmRevoke(null)}>
                    Cancel
                  </button>
                </div>
              ) : (
                <button
                  className="setup-btn ghost"
                  onClick={() => setConfirmRevoke(device.id)}
                  aria-label={`Revoke ${device.name}`}
                >
                  <Trash2 size={14} />
                  Revoke
                </button>
              )}
            </div>
          ))
        )}
      </div>
    </section>
  );
}
