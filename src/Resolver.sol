// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Initializable} from "openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {FakeableERC20} from "fakeable/FakeableERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {MarketsSlots} from "./MarketsSlots.sol";

/// ResolverStake — the real-only stake wrapper (fake minting disabled). Kept
/// separate from the Resolver engine for EIP-170 headroom.
contract ResolverStake is FakeableERC20 {
    function initialize(IERC20 underlying_, string memory name_, string memory symbol_) external initializer {
        __FakeableERC20_init(name_, symbol_, underlying_);
    }

    function _authorizeFakeMint(address) internal pure override returns (bool) {
        return false;
    }
}

interface IEvent {
    function state() external view returns (uint8 status, uint8 winner, uint256 resolutionBlock);
    function resolve(uint8 winner) external;
    function defer(uint256 newResolutionBlock) external;
    function outcomeCount() external view returns (uint8);
}

/// Resolver — a real-only FakeableERC20 stake token (fake minting disabled) plus
/// the stake-weighted resolution protocol (plan §2.3/§2.3a): rounds with escrowed
/// votes, plurality + quorum, slash-the-losers/reward-the-winners, DEFER with
/// escalating windows, and an appeal layer (bond + escalating window/quorum,
/// bounded finality at Lmax). Only at finality does it push event.resolve(w).
///
/// Settlement conservation: a round's slashed pool funds (a) the appellant's
/// reserved share (if this round was opened by an appeal that overturned) and (b)
/// the winners' pro-rata shares of the remainder. Claims never exceed escrowed +
/// slashed stake. A burned appeal bond simply stays in the contract (unclaimable
/// float).
contract Resolver is Initializable {
    uint8 internal constant DEFER = type(uint8).max;

    enum RoundStatus {
        Voting,
        Concluded, // provisional — challenge window open
        Final // pushed to the event, deferred, or superseded by an appeal round
    }

    struct Round {
        address event_;
        uint8 level;
        uint64 startBlock;
        uint64 window;
        RoundStatus status;
        uint8 winner; // DEFER sentinel possible
        uint256 totalVoted;
        uint256 winningStake;
        uint256 slashedPool;
        uint256 slashReserved; // appellant share (overturned appeals)
        uint64 challengeEnd;
        // appeal metadata (this round was opened by an appeal of a prior round)
        address appellant;
        uint256 appealBond;
        uint8 priorWinner;
        bool fromAppeal;
    }

    struct ResolverStorage {
        address owner;
        FakeableERC20 stakeToken;
        uint16 slashBps; // s
        uint16 quorumBps; // q (of stake supply)
        uint64 window; // W
        uint64 deferPeriod; // D
        uint64 windowMax; // Wmax
        uint64 challengeWindow; // C
        uint8 levelMax; // Lmax
        uint16 appellantShareBps; // a
        uint256 appealBond; // B (stake tokens)
        mapping(address => uint8) levelOf; // event => next round level
        mapping(bytes32 => Round) rounds;
        mapping(bytes32 => mapping(uint8 => uint256)) tally; // choice => stake (255 = DEFER)
        mapping(bytes32 => mapping(address => uint8)) choiceOf;
        mapping(bytes32 => mapping(address => uint256)) escrowOf;
        mapping(address => bytes32) latestRound; // event => roundId
    }

    event RoundOpened(bytes32 indexed roundId, address indexed event_, uint8 level, uint64 window);
    event Voted(bytes32 indexed roundId, address indexed voter, uint8 choice, uint256 stake);
    event Concluded(bytes32 indexed roundId, uint8 winner, uint256 slashedPool);
    event Appealed(bytes32 indexed priorRound, bytes32 indexed newRound, address appellant);
    event Finalized(bytes32 indexed roundId, address indexed event_, uint8 winner);
    event Claimed(bytes32 indexed roundId, address indexed voter, uint256 payout);

    error RoundNotOpen();
    error VotingActive();
    error BadChoice();
    error ChallengeActive();
    error NotConcluded();
    error InvalidAppeal();

    function _rs() internal pure returns (ResolverStorage storage s) {
        bytes32 slot = MarketsSlots.RESOLVER_SLOT;
        assembly {
            s.slot := slot
        }
    }

    struct Params {
        uint16 slashBps;
        uint16 quorumBps;
        uint64 window;
        uint64 deferPeriod;
        uint64 windowMax;
        uint64 challengeWindow;
        uint8 levelMax;
        uint16 appellantShareBps;
        uint256 appealBond;
    }

    function initialize(FakeableERC20 stakeToken_, address owner_, Params memory p) external initializer {
        ResolverStorage storage s = _rs();
        s.owner = owner_;
        s.stakeToken = stakeToken_;
        s.slashBps = p.slashBps;
        s.quorumBps = p.quorumBps;
        s.window = p.window;
        s.deferPeriod = p.deferPeriod;
        s.windowMax = p.windowMax;
        s.challengeWindow = p.challengeWindow;
        s.levelMax = p.levelMax;
        s.appellantShareBps = p.appellantShareBps;
        s.appealBond = p.appealBond;
    }

    function stakeToken() external view returns (FakeableERC20) {
        return _rs().stakeToken;
    }

    function roundIdOf(address event_, uint8 level) public pure returns (bytes32) {
        return keccak256(abi.encode(event_, level));
    }

    function getRound(bytes32 rid) external view returns (Round memory) {
        return _rs().rounds[rid];
    }

    function tallyOf(bytes32 rid, uint8 choice) external view returns (uint256) {
        return _rs().tally[rid][choice];
    }

    function escrowOf(bytes32 rid, address voter) external view returns (uint256) {
        return _rs().escrowOf[rid][voter];
    }

    function choiceOf(bytes32 rid, address voter) external view returns (uint8) {
        return _rs().choiceOf[rid][voter];
    }

    // ── rounds ───────────────────────────────────────────────────────────────

    /// Open a round for an event (permissionless) once it matured and has no live
    /// round.
    function openRound(address event_) external returns (bytes32 rid) {
        ResolverStorage storage s = _rs();
        (uint8 status,, uint256 rb) = IEvent(event_).state();
        require(status == 0, "event not open");
        require(block.number >= rb, "not mature");
        bytes32 prevRid = s.latestRound[event_];
        if (prevRid != bytes32(0)) {
            require(s.rounds[prevRid].status != RoundStatus.Voting, "round live");
        }
        uint8 level = s.levelOf[event_];
        rid = roundIdOf(event_, level);
        _openRound(s, rid, event_, level);
    }

    function _openRound(ResolverStorage storage s, bytes32 rid, address event_, uint8 level) internal {
        Round storage r = s.rounds[rid];
        r.event_ = event_;
        r.level = level;
        r.startBlock = uint64(block.number);
        r.window = _windowFor(s, level);
        r.status = RoundStatus.Voting;
        s.latestRound[event_] = rid;
        emit RoundOpened(rid, event_, level, r.window);
    }

    function _windowFor(ResolverStorage storage s, uint8 level) internal view returns (uint64) {
        uint64 w = s.window;
        for (uint8 i; i < level; i++) {
            uint64 dbl = w * 2;
            w = dbl > s.windowMax || dbl < w ? s.windowMax : dbl;
        }
        return w;
    }

    function _quorumFor(ResolverStorage storage s, uint8 level) internal view returns (uint256) {
        uint256 supply = s.stakeToken.realSupply();
        uint256 bps = uint256(s.quorumBps) << level; // q·2^L, capped at full supply
        if (bps >= 10_000) return supply;
        return (supply * bps) / 10_000;
    }

    /// Vote with escrowed stake; re-voting moves the whole stake. Choice = outcome
    /// index or 255 (DEFER).
    function vote(bytes32 rid, uint8 choice, uint256 stake) external {
        ResolverStorage storage s = _rs();
        Round storage r = s.rounds[rid];
        if (r.status != RoundStatus.Voting || block.number >= r.startBlock + r.window) revert RoundNotOpen();
        if (choice != DEFER && choice >= IEvent(r.event_).outcomeCount()) revert BadChoice();
        uint256 oldStake = s.escrowOf[rid][msg.sender];
        if (oldStake != 0) {
            s.tally[rid][s.choiceOf[rid][msg.sender]] -= oldStake;
            r.totalVoted -= oldStake;
        }
        if (stake != 0) {
            // escrowed via allowance (approve the resolver once)
            require(s.stakeToken.transferFrom(msg.sender, address(this), stake), "escrow failed");
            s.tally[rid][choice] += stake;
            r.totalVoted += stake;
        }
        s.escrowOf[rid][msg.sender] = stake;
        s.choiceOf[rid][msg.sender] = choice;
        emit Voted(rid, msg.sender, choice, stake);
    }

    /// Close voting and tally. Plurality wins; quorum failure auto-defers.
    function concludeRound(bytes32 rid) external {
        ResolverStorage storage s = _rs();
        Round storage r = s.rounds[rid];
        if (r.status != RoundStatus.Voting) revert RoundNotOpen();
        if (block.number < r.startBlock + r.window) revert VotingActive();

        uint8 n = IEvent(r.event_).outcomeCount();
        uint8 winner = DEFER;
        uint256 best = s.tally[rid][DEFER];
        for (uint8 k; k < n; k++) {
            uint256 t = s.tally[rid][k];
            if (t > best) {
                best = t;
                winner = k;
            }
        }
        if (r.totalVoted < _quorumFor(s, r.level)) winner = DEFER; // quorum failure
        r.winner = winner;

        // Appeal-bond settlement (this round was opened by an appeal).
        if (r.fromAppeal) {
            if (winner == r.priorWinner) {
                // Upheld: bond burns (stays as unclaimable float in the contract).
            } else if (winner == DEFER) {
                // Defer: bond refundable via claim.
            } // overturned: bond refundable + reserved share (set after slashing)
        }

        if (winner == DEFER) {
            r.status = RoundStatus.Final;
            s.levelOf[r.event_] = 0;
            IEvent(r.event_).defer(block.number + s.deferPeriod);
            emit Concluded(rid, DEFER, 0);
            return;
        }

        uint256 slash;
        for (uint8 k; k < n; k++) {
            if (k == winner) continue;
            slash += (s.tally[rid][k] * s.slashBps) / 10_000;
        }
        r.slashedPool = slash;
        if (r.fromAppeal && winner != r.priorWinner) {
            r.slashReserved = (slash * s.appellantShareBps) / 10_000;
        }
        r.winningStake = best;
        r.status = RoundStatus.Concluded;
        r.challengeEnd = uint64(block.number) + s.challengeWindow;
        emit Concluded(rid, winner, slash);
    }

    // ── appeals (§2.3a) ─────────────────────────────────────────────────────

    /// Appeal a concluded provisional outcome: posts the bond and opens the next
    /// round at level+1 (escalated window/quorum). Bond burns if upheld, returns if
    /// the appeal round overturns or defers.
    function appeal(bytes32 rid, uint8 differentOutcome) external returns (bytes32 newRid) {
        ResolverStorage storage s = _rs();
        Round storage r = s.rounds[rid];
        if (r.status != RoundStatus.Concluded) revert NotConcluded();
        if (block.number >= r.challengeEnd) revert ChallengeActive();
        if (r.level >= s.levelMax) revert InvalidAppeal();
        if (differentOutcome == r.winner) revert InvalidAppeal();
        if (differentOutcome != DEFER && differentOutcome >= IEvent(r.event_).outcomeCount()) revert BadChoice();
        require(s.stakeToken.transferFrom(msg.sender, address(this), s.appealBond), "bond failed");
        r.status = RoundStatus.Final; // superseded — no plain finalize possible
        uint8 level = r.level + 1;
        s.levelOf[r.event_] = level;
        newRid = roundIdOf(r.event_, level);
        _openRound(s, newRid, r.event_, level);
        Round storage nr = s.rounds[newRid];
        nr.fromAppeal = true;
        nr.appellant = msg.sender;
        nr.appealBond = s.appealBond;
        nr.priorWinner = r.winner;
        emit Appealed(rid, newRid, msg.sender);
    }

    /// Push finality: challenge window passed (or Lmax reached) → event.resolve.
    function finalizeRound(bytes32 rid) external {
        ResolverStorage storage s = _rs();
        Round storage r = s.rounds[rid];
        if (r.status != RoundStatus.Concluded) revert NotConcluded();
        if (r.level < s.levelMax && block.number < r.challengeEnd) revert ChallengeActive();
        r.status = RoundStatus.Final;
        s.levelOf[r.event_] = 0;
        IEvent(r.event_).resolve(r.winner);
        emit Finalized(rid, r.event_, r.winner);
    }

    // ── claims (pull-based escrow + reward return) ───────────────────────────

    /// Return escrow plus rewards after a round ends. Losers get stake − slash;
    /// winners add pro-rata shares of (slashedPool − slashReserved); DEFER voters
    /// and defer rounds return stake whole. The appellant claims bond (+ reserved
    /// share on overturn) from the APPEAL round; upheld bonds are burned (float).
    function claim(bytes32 rid) external {
        ResolverStorage storage s = _rs();
        Round storage r = s.rounds[rid];
        require(r.status != RoundStatus.Voting, "round live");
        uint256 payout;

        uint256 stake = s.escrowOf[rid][msg.sender];
        if (stake != 0) {
            s.escrowOf[rid][msg.sender] = 0;
            uint8 c = s.choiceOf[rid][msg.sender];
            if (r.winner == DEFER || c == DEFER) {
                payout = stake;
            } else if (c == r.winner) {
                uint256 pool = r.slashedPool - r.slashReserved;
                payout = stake + (r.winningStake == 0 ? 0 : (stake * pool) / r.winningStake);
            } else {
                payout = stake - (stake * s.slashBps) / 10_000;
            }
        }

        if (msg.sender == r.appellant && r.appealBond != 0) {
            if (r.winner == r.priorWinner) {
                r.appealBond = 0; // upheld: burned (stays as contract float)
            } else {
                uint256 b = r.appealBond;
                r.appealBond = 0;
                payout += b + r.slashReserved; // reserved stays set for winner math
            }
        }

        require(payout != 0, "nothing to claim");
        emit Claimed(rid, msg.sender, payout); // state zeroed above; CEI-safe
        require(s.stakeToken.transfer(msg.sender, payout), "payout failed"); // contract pays out escrow
    }

    uint256[50] private __resolverGap;
}
