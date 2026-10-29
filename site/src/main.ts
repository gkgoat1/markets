// Markets dApp — credits-first, address-first, trustless (plan §5).
// Verification model: an event is trusted iff (a) it was emitted by the configured
// factory's EventCreated log (explore mode) or (b) its beacon-proxy implementation
// resolves through the configured beacon to the version-pinned trusted
// implementation (address mode). Inputs are on-chain only; no backend.
import { BrowserProvider, Contract, Interface, formatUnits, getAddress, parseUnits } from "ethers";

interface Config {
  rpcUrl?: string;
  factory: string;
  eventBeacon: string;
  outcomeBeacon: string;
  trustedEventImpl: string;
  trustedOutcomeImpl: string;
  underlying: string;
  resolver: string;
  credits: string;
}

const ERC1967_BEACON_SLOT = "0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50";

const EVENT_IFACE = new Interface([
  "function state() view returns (uint8 status, uint8 winner, uint256 resolutionBlock)",
  "function outcomeCount() view returns (uint8)",
  "function outcomeToken(uint8) view returns (address)",
  "function metadataURI() view returns (string)",
  "function deposit(uint8 outcome, uint256 amount)",
  "function redeem(uint8 outcome)",
]);
const TOKEN_IFACE = new Interface([
  "function balanceOf(address) view returns (uint256)",
  "function realOf(address) view returns (uint256)",
  "function fakeOf(address) view returns (uint256)",
]);
const CREDITS_IFACE = new Interface([
  "function creditsOf(address) view returns (uint256)",
  "function claimWelcome()",
  "function convertToFake(address event_, uint8 outcome, uint256 amount)",
  "function convertToCredits(address event_, uint8 outcome, uint256 amount)",
]);
const UNDERLYING_IFACE = new Interface([
  "function approve(address spender, uint256 amount) returns (bool)",
  "function decimals() view returns (uint8)",
]);
const FACTORY_IFACE = new Interface(["event EventCreated(address indexed event_, address indexed underlying, uint8 outcomes, uint256 resolutionBlock, string metadataURI)"]);

declare global {
  interface Window {
    ethereum?: { request: (a: { method: string; params?: unknown[] }) => Promise<unknown> };
  }
}

const app = document.getElementById("app")!;
let cfg: Config;
let provider: BrowserProvider;
let account: string | null = null;
let creditsMode = true; // credits-first default

function el(html: string) {
  app.innerHTML = html;
}

async function init() {
  cfg = await (await fetch("/config.json")).json();
  render();
}

function render() {
  el(`
    <div class="card row">
      <button id="connect">${account ? account.slice(0, 10) + "…" : "connect wallet"}</button>
      <label><input type="checkbox" id="mode" ${creditsMode ? "checked" : ""}/> credits mode</label>
      ${account ? `<span id="balances" class="muted"></span>` : ""}
    </div>
    <div class="card">
      <h3>Open an event by address</h3>
      <div class="row"><input id="addr" placeholder="0x… event address"/><button id="open">verify & open</button></div>
      <div id="openStatus" class="muted"></div>
    </div>
    <div class="card">
      <h3>Explore events (on-chain logs)</h3>
      <button id="explore">scan factory logs</button>
      <div id="events"></div>
    </div>
    <div id="detail"></div>
  `);
  document.getElementById("connect")!.onclick = connect;
  document.getElementById("mode")!.onchange = (e) => {
    creditsMode = (e.target as HTMLInputElement).checked;
    render();
  };
  document.getElementById("open")!.onclick = openByAddress;
  document.getElementById("explore")!.onclick = explore;
  if (account) refreshBalances();
}

async function connect() {
  if (!window.ethereum) {
    alert("no EIP-1193 wallet");
    return;
  }
  provider = new BrowserProvider(window.ethereum);
  const accounts = (await window.ethereum.request({ method: "eth_requestAccounts" })) as string[];
  account = getAddress(accounts[0]);
  render();
}

async function refreshBalances() {
  if (!account) return;
  const credits = new Contract(cfg.credits, CREDITS_IFACE, provider);
  const c = (await credits.creditsOf(account)) as bigint;
  document.getElementById("balances")!.innerHTML = `credits: <span class="credits">${c.toString()}</span>`;
}

/// Trustless verification (address mode): the address must be an ERC1967 beacon
/// proxy whose beacon's implementation is the version-pinned trusted Event impl.
async function verifyEvent(addr: string): Promise<string | null> {
  const code = await provider.getCode(addr);
  if (code === "0x") return "no contract at that address";
  const beaconWord = await provider.getStorage(addr, ERC1967_BEACON_SLOT);
  const beacon = getAddress("0x" + beaconWord.slice(26));
  if (beacon.toLowerCase() !== cfg.eventBeacon.toLowerCase()) return "not a proxy of the trusted event beacon";
  const beaconC = new Contract(beacon, ["function implementation() view returns (address)"], provider);
  const impl = (await beaconC.implementation()) as string;
  if (impl.toLowerCase() !== cfg.trustedEventImpl.toLowerCase()) return "untrusted implementation (wrong version)";
  return null;
}

async function openByAddress() {
  const status = document.getElementById("openStatus")!;
  if (!account) return (status.textContent = "connect first");
  let addr: string;
  try {
    addr = getAddress((document.getElementById("addr") as HTMLInputElement).value.trim());
  } catch {
    return (status.textContent = "invalid address");
  }
  status.textContent = "verifying on-chain…";
  const err = await verifyEvent(addr);
  if (err) return (status.innerHTML = `<span class="err">✗ ${err}</span>`);
  status.innerHTML = `<span class="ok">✓ verified event</span>`;
  await showEvent(addr);
}

/// Explore mode: factory logs straight from the RPC (no indexer, no backend).
async function explore() {
  if (!account) await connect();
  const div = document.getElementById("events")!;
  div.textContent = "scanning…";
  const factory = new Contract(cfg.factory, FACTORY_IFACE, provider);
  const logs = await factory.queryFilter("EventCreated", 0, "latest");
  if (logs.length === 0) return (div.textContent = "no events yet");
  div.innerHTML = logs
    .map((l) => {
      const e = (l as unknown as { args: { event_: string; resolutionBlock: bigint; metadataURI: string } }).args;
      return `<div class="row"><code>${e.event_}</code> <span class="muted">${e.metadataURI} · resolves at block ${e.resolutionBlock}</span>
        <button data-addr="${e.event_}" class="openEvt">open</button></div>`;
    })
    .join("");
  for (const b of document.querySelectorAll<HTMLButtonElement>(".openEvt")) {
    b.onclick = () => showEvent(b.dataset.addr!);
  }
}

async function showEvent(addr: string) {
  if (!account) await connect();
  const evt = new Contract(addr, EVENT_IFACE, provider);
  const [status, winner, rb] = (await evt.state()) as [bigint, bigint, bigint];
  const n = Number(await evt.outcomeCount());
  const meta = (await evt.metadataURI()) as string;
  const statusName = ["Open", "Resolved", "Unwound"][Number(status)];
  const rows: string[] = [];
  const credits = new Contract(cfg.credits, CREDITS_IFACE, provider);
  const myCredits = (await credits.creditsOf(account!)) as bigint;

  for (let k = 0; k < n; k++) {
    const t = new Contract((await evt.outcomeToken(k)) as string, TOKEN_IFACE, provider);
    const [real, fake] = (await Promise.all([t.realOf(account!), t.fakeOf(account!)])) as [bigint, bigint];
    rows.push(`
      <div class="card">
        <b>outcome #${k}</b>
        <span class="muted"> · you: <span class="real">${real}</span> real + <span class="credits">${fake}</span> fake</span>
        <div class="row">
          <input id="amt${k}" placeholder="amount" type="number" min="0"/>
          <button id="go${k}">${creditsMode ? "convert credits → fake" : "deposit real"}</button>
          ${Number(status) !== 0 ? `<button id="red${k}">redeem</button>` : ""}
        </div>
      </div>`);
  }

  document.getElementById("detail")!.innerHTML = `
    <div class="card">
      <h3>${meta}</h3>
      <div class="muted"><code>${addr}</code></div>
      <div>status: <b>${statusName}</b>${Number(status) === 1 ? ` — winner: outcome #${winner}` : ""}
        · resolution block ${rb}</div>
      <div class="row">credits: <span class="credits">${myCredits}</span>
        <button id="welcome">claim welcome credits</button></div>
      ${rows.join("")}
    </div>`;

  document.getElementById("welcome")!.onclick = async () => {
    const s = await provider.getSigner();
    await (await new Contract(cfg.credits, CREDITS_IFACE, s).claimWelcome()).wait();
    showEvent(addr);
  };
  for (let k = 0; k < n; k++) {
    document.getElementById(`go${k}`)!.onclick = async () => {
      const amt = BigInt((document.getElementById(`amt${k}`) as HTMLInputElement).value || "0");
      if (amt <= 0n) return;
      const s = await provider.getSigner();
      if (creditsMode) {
        await (await new Contract(cfg.credits, CREDITS_IFACE, s).convertToFake(addr, k, amt)).wait();
      } else {
        const u = new Contract(cfg.underlying, UNDERLYING_IFACE, s);
        await (await u.approve(addr, amt)).wait();
        await (await new Contract(addr, EVENT_IFACE, s).deposit(k, amt)).wait();
      }
      showEvent(addr);
    };
    const red = document.getElementById(`red${k}`);
    if (red) {
      red.onclick = async () => {
        const s = await provider.getSigner();
        await (await new Contract(addr, EVENT_IFACE, s).redeem(k)).wait();
        showEvent(addr);
      };
    }
  }
}

init();
