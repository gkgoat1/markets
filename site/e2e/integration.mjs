// M-7 e2e: full user flow against a fresh anvil, using the dApp's config and ABIs.
// Spins anvil, deploys the stack via script/Deploy.s.sol, then: welcome credits →
// convert to fake → deposit real → resolver round (vote, conclude, finalize) →
// redeem (real → underlying, fake → credits). Exits nonzero on any failure.
import { spawn, execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { JsonRpcProvider, Wallet, Contract, ContractFactory, NonceManager } from "ethers";

const ROOT = new URL("../..", import.meta.url).pathname;
const PORT = 8400 + (process.pid % 180);
const RPC = `http://127.0.0.1:${PORT}`;
const KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"; // anvil #0

const ANVIL = "/opt/homebrew/bin/anvil";
const FORGE = "/opt/homebrew/bin/forge";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const rpc = (method, params = []) =>
  fetch(RPC, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });

let step = "init";
async function main() {
  const anvil = spawn(ANVIL, ["--port", String(PORT), "--silent"], { stdio: "ignore" });
  try {
    await waitRpc();
    // deploy the mock underlying straight from the compiled artifact
    const art = JSON.parse(readFileSync(`${ROOT}/out/MockERC20.sol/MockERC20.json`, "utf8"));
    const me0 = new NonceManager(new Wallet(KEY, new JsonRpcProvider(RPC)));
    const factory0 = new ContractFactory(art.abi, art.bytecode.object, me0);
    const mock = await factory0.deploy();
    await mock.waitForDeployment();
    const underlying = await mock.getAddress();
    execFileSync(FORGE, ["script", "script/Deploy.s.sol", "--rpc-url", RPC, "--broadcast", "--private-key", KEY], {
      cwd: ROOT,
      env: { ...process.env, UNDERLYING: underlying },
      stdio: "pipe",
    });
    const cfg = JSON.parse(readFileSync(`${ROOT}/site/public/config.deployed.json`, "utf8"));
    const probe = new JsonRpcProvider(RPC);
    const code = await probe.getCode(cfg.factory);
    if (code === "0x") throw new Error("stale config.deployed.json — factory has no code on this chain");

    const provider = new JsonRpcProvider(RPC);
    const me = new NonceManager(new Wallet(KEY, provider));
    const meAddr = await me.getAddress();
    const factory = new Contract(cfg.factory, [
      "function createEvent(address underlying, uint8 outcomes, uint256 resolutionBlock, string metadataURI) returns (address, address[])",
      "function eventAt(uint256) view returns (address)",
    ], me);
    const erc20 = ["function approve(address,uint256) returns (bool)", "function balanceOf(address) view returns (uint256)", "function mint(address,uint256)"];
    const u = new Contract(underlying, erc20, me);

    console.log("cfg:", cfg.factory, cfg.credits, cfg.resolver, underlying);
    const block = await provider.getBlockNumber();
    await (await factory.createEvent(underlying, 2, block + 40, "e2e://event")).wait();
    const eventAddr = await factory.eventAt(0); console.log("event:", eventAddr, "meAddr:", meAddr);
    const evt = new Contract(eventAddr, [
      "function deposit(uint8,uint256)", "function redeem(uint8)",
      "function outcomeToken(uint8) view returns (address)", "function state() view returns (uint8,uint8,uint256)",
    ], me);
    const credits = new Contract(cfg.credits, [
      "function claimWelcome()", "function convertToFake(address,uint8,uint256)",
      "function creditsOf(address) view returns (uint256)",
    ], me);
    const resolver = new Contract(cfg.resolver, [
      "function wrap(uint256)", "function openRound(address) returns (bytes32)",
      "function vote(bytes32,uint8,uint256)", "function concludeRound(bytes32)",
      "function finalizeRound(bytes32)", "function roundIdOf(address,uint8) view returns (bytes32)",
    ], me);

    // credits flow (dApp default)
    step = "claimWelcome"; await (await credits.claimWelcome()).wait();
    step = "convertToFake"; await (await credits.convertToFake(eventAddr, 0, 500)).wait();
    const t0 = new Contract(await evt.outcomeToken(0), ["function fakeOf(address) view returns (uint256)", "function realOf(address) view returns (uint256)"], me);
    assert((await t0.fakeOf(meAddr)) === 500n, "fake minted");

    // real deposit on outcome 1
    step = "mint"; await (await u.mint(meAddr, 4000)).wait();
    await (await u.approve(eventAddr, 1000)).wait();
    step = "deposit"; await (await evt.deposit(1, 1000)).wait();

    // stake + resolve: winner = 0 (so the fake position recredits)
    const stake = new Contract(cfg.stakeToken, ["function wrap(uint256)", "function approve(address,uint256) returns (bool)"], me);
    await (await u.approve(cfg.stakeToken, 2000)).wait();
    step = "wrap"; await (await stake.wrap(2000)).wait();
    await (await stake.approve(cfg.resolver, 2000)).wait();
    await mine(41); // past resolution block
    step = "openRound"; await (await resolver.openRound(eventAddr)).wait();
    const rid = await resolver.roundIdOf(eventAddr, 0);
    step = "vote"; await (await resolver.vote(rid, 0, 2000)).wait();
    await mine(7201); // window
    step = "conclude"; await (await resolver.concludeRound(rid)).wait();
    await mine(3601); // challenge window
    step = "finalize"; await (await resolver.finalizeRound(rid)).wait();
    const [status, winner] = await evt.state();
    assert(status === 1n && winner === 0n, "resolved to outcome 0");

    // redeem: fake 500 of winner 0 at rate 1000/500... pool=1000, S_w=500 fake only → rate 2 → 1000 credits
    const before = await credits.creditsOf(meAddr);
    step = "redeem0"; await (await evt.redeem(0)).wait();
    const after = await credits.creditsOf(meAddr);
    assert(after - before === 1000n, `recredited at rate (${after - before})`);
    // losing outcome redeem is a no-op
    step = "redeem1"; await (await evt.redeem(1)).wait();
    const t1 = new Contract(await evt.outcomeToken(1), ["function realOf(address) view returns (uint256)"], me);
    assert((await t1.realOf(meAddr)) === 1000n, "loser no-op keeps tokens");

    console.log("e2e: PASS");
  } finally {
    anvil.kill();
  }
}

function assert(cond, msg) {
  if (!cond) {
    console.error("e2e FAIL:", msg, new Error().stack.split("\n")[2]);
    process.exit(1);
  }
}

async function waitRpc() {
  for (let i = 0; i < 50; i++) {
    try {
      const r = await rpc("eth_blockNumber");
      if (!r.ok) continue;
      // freshness: a zombie on the port has old state; require nonce 0 for the key
      const n = await rpc("eth_getTransactionCount", ["0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266", "latest"]);
      const j = await n.json();
      if (j.result === "0x0") return;
    } catch {}
    await sleep(200);
  }
  throw new Error("anvil did not start");
}
async function mine(n) {
  await rpc("anvil_mine", [n]);
}

main().catch((e) => {
  console.error("e2e FAIL at step:", step, "-", e.stack ? e.stack.split(String.fromCharCode(10)).slice(0,9).join(" | ") : e);
  process.exit(1);
});
