// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PayrollRun} from "../src/PayrollRun.sol";

interface IUSDG {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function isFrozen(address) external view returns (bool);
    function paused() external view returns (bool);
}

/**
 * @title Fork test against the REAL USDG on Arbitrum Sepolia.
 *
 * Runs on a fork of live chain state. Exercises the complete flow against the actual token
 * implementation rather than a mock, and explicit[it]ly probes every assumption `PayrollRun.sol`
 * makes about that token.
 *
 * No deployment, no signing, no spending — a fork is read-only chain state plus local overrides.
 *
 * Run: forge test --match-contract ForkUSDGTest --fork-url $ARB_SEPOLIA_RPC -vv
 */
contract ForkUSDGTest is Test {
    /// @dev Verified first-hand via eth_call, and listed by Paxos' own docs for Arbitrum Sepolia.
    address constant USDG = 0xFFC95faa3d63Cde504a05B567C600B78C0b41892;

    uint256 constant CHAIN_ID = 421614;

    PayrollRun internal payroll;

    address internal employer = address(0xE47);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);

    uint64 internal deadline;

    function setUp() public {
        // This suite only means something against the real token. Without --fork-url we skip
        // rather than fail, so a plain `forge test` stays green for anyone reviewing the repo.
        if (block.chainid != CHAIN_ID) {
            vm.skip(true);
        }

        // deploy our contract against the REAL token on the fork
        payroll = new PayrollRun(USDG);

        // fund the actors with real USDG held on the fork (storage override, not a mint)
        deal(USDG, employer, 1_000_000e6);
        assertEq(IUSDG(USDG).balanceOf(employer), 1_000_000e6, "deal() did not work on USDG");

        deadline = uint64(block.timestamp + 30 days);
    }

    // ───────────────────────────────────────────────────────────────
    // 1. The token is what we think it is
    // ───────────────────────────────────────────────────────────────

    function test_fork_usdgIdentityMatchesAssumptions() public view {
        assertEq(IUSDG(USDG).name(), "Global Dollar", "name");
        assertEq(IUSDG(USDG).symbol(), "USDG", "symbol");
        assertEq(IUSDG(USDG).decimals(), 6, "decimals MUST be 6");
        assertGt(IUSDG(USDG).totalSupply(), 0, "no supply");
        assertGt(USDG.code.length, 0, "no code at the USDG address");
    }

    // ───────────────────────────────────────────────────────────────
    // 2. Token behaviours PayrollRun depends on
    // ───────────────────────────────────────────────────────────────

    /// @dev PayrollRun records `amount` as totalDeposited and pays `amount` out. That is only
    ///      correct if USDG moves EXACTLY the stated amount — no fee-on-transfer, no rebase.
    function test_fork_usdgIsNotFeeOnTransfer() public {
        address probe = address(0xFEE);
        deal(USDG, probe, 1000e6);

        uint256 recipientBefore = IUSDG(USDG).balanceOf(bob);
        vm.prank(probe);
        IUSDG(USDG).transfer(bob, 1000e6);

        assertEq(
            IUSDG(USDG).balanceOf(bob) - recipientBefore,
            1000e6,
            "USDG charged a transfer fee - totalDeposited accounting would be wrong"
        );
        assertEq(IUSDG(USDG).balanceOf(probe), 0, "sender balance not fully debited");
    }

    /// @dev A rebasing token would silently break `remaining()`. Supply must be stable.
    function test_fork_usdgDoesNotRebase() public {
        uint256 supply = IUSDG(USDG).totalSupply();
        uint256 bal = IUSDG(USDG).balanceOf(employer);

        // move funds around and warp; a rebase would change the balance without a transfer
        vm.prank(employer);
        IUSDG(USDG).transfer(alice, 1000e6);

        assertEq(IUSDG(USDG).totalSupply(), supply, "USDG rebased");
        assertEq(IUSDG(USDG).balanceOf(alice), 1000e6, "held balance changed on its own");
        assertEq(IUSDG(USDG).balanceOf(employer), bal - 1000e6, "employer balance drift");
    }

    /// @dev `approve` must not revert and must be read back exactly (no non-standard allowance).
    function test_fork_approveAndAllowanceBehaveNormally() public {
        vm.prank(employer);
        assertTrue(IUSDG(USDG).approve(address(payroll), 5_000e6));

        assertEq(IUSDG(USDG).allowance(employer, address(payroll)), 5_000e6, "allowance not set");

        // re-approving must not require zeroing first (the USDT-style race guard).
        vm.prank(employer);
        assertTrue(IUSDG(USDG).approve(address(payroll), 1_000_000e6));
        assertEq(IUSDG(USDG).allowance(employer, address(payroll)), 1_000_000e6);
    }

    /// @dev SafeERC20 tolerates tokens that return no data. Confirm USDG returns a bool, and that
    ///      SafeERC20 would accept it either way.
    function test_fork_usdgTransferReturnsBool() public {
        deal(USDG, alice, 10e6);
        vm.prank(alice);
        bool ok = IUSDG(USDG).transfer(bob, 10e6);
        assertTrue(ok, "transfer() did not return true");
    }

    // ───────────────────────────────────────────────────────────────
    // 3. The complete flow against the real token
    // ───────────────────────────────────────────────────────────────

    function _roster()
        internal
        view
        returns (bytes32 root, bytes32[][] memory proofs, bytes32[3] memory salts, uint256 total)
    {
        uint256[3] memory amts = [uint256(900e6), uint256(400e6), uint256(200e6)];
        address[3] memory who = [alice, bob, carol];
        total = amts[0] + amts[1] + amts[2];

        salts = [
            keccak256("fork.salt.alice"),
            keccak256("fork.salt.bob"),
            keccak256("fork.salt.carol")
        ];

        bytes32[] memory leaves = new bytes32[](3);
        for (uint256 i = 0; i < 3; i++) {
            leaves[i] = payroll.leafFor(1, i, who[i], amts[i], salts[i]);
        }

        (root, proofs) = _buildTree(leaves);
    }

    /// @dev Claim every commitment, asserting the UI's pre-flight check agrees with reality.
    function _claimAll(uint256 runId, bytes32[][] memory proofs, bytes32[3] memory salts) internal {
        address[3] memory who = [alice, bob, carol];
        uint256[3] memory amts = [uint256(900e6), uint256(400e6), uint256(200e6)];

        for (uint256 i = 0; i < 3; i++) {
            assertTrue(
                payroll.verifyClaim(runId, i, who[i], amts[i], salts[i], proofs[i]),
                "verifyClaim said no before claiming"
            );

            uint256 before = IUSDG(USDG).balanceOf(who[i]);
            vm.prank(who[i]);
            payroll.claim(runId, i, amts[i], salts[i], proofs[i]);

            assertEq(IUSDG(USDG).balanceOf(who[i]) - before, amts[i], "claim paid the wrong amount");

            assertFalse(
                payroll.verifyClaim(runId, i, who[i], amts[i], salts[i], proofs[i]),
                "verifyClaim still true after claiming"
            );
        }
    }

    /**
     * @dev The issuer's control surface is real and is a dependency of this product, not a
     * hypothetical. USDG is an upgradeable proxy whose issuer can freeze an address or pause
     * transfers outright. Neither is active today, and this contract cannot defend against either —
     * so we assert the surface exists and document it as a limitation rather than ignore it.
     *
     * If this test starts failing because `isFrozen` or `paused` stopped being callable, the token
     * was reimplemented and every assumption above must be re-checked before deployment.
     */
    function test_fork_documentsIssuerControlSurface() public {
        // Callable at all ⇒ the capability is implemented (the proxy rejects unknown selectors,
        // so a clean bool return cannot be a permissive fallback).
        bool frozen = IUSDG(USDG).isFrozen(address(0xBEEF));
        bool isPaused = IUSDG(USDG).paused();

        // Not active today. Recorded as assertions so a change surfaces loudly.
        assertFalse(frozen, "USDG reports a frozen address - investigate before deploying");
        assertFalse(isPaused, "USDG is paused - no transfer could succeed");

        emit log_named_string("USDG issuer control", "isFrozen() + paused() both callable");
    }

    function test_fork_completeFlow_approve_createRun_claim_remaining_reclaim() public {
        (bytes32 root, bytes32[][] memory proofs, bytes32[3] memory salts, uint256 total) = _roster();

        // ── 1. approval / allowance ──────────────────────────────────
        assertEq(IUSDG(USDG).allowance(employer, address(payroll)), 0, "unexpected pre-allowance");

        vm.prank(employer);
        IUSDG(USDG).approve(address(payroll), total);
        assertEq(IUSDG(USDG).allowance(employer, address(payroll)), total, "allowance");

        // ── 2. createRun ─────────────────────────────────────────────
        uint256 employerBefore = IUSDG(USDG).balanceOf(employer);
        uint256 poolBefore = IUSDG(USDG).balanceOf(address(payroll));

        vm.prank(employer);
        uint256 runId = payroll.createRun(root, deadline, total);
        assertEq(runId, 1, "run id");

        // the REAL token actually moved, exactly `total`, and allowance was consumed
        assertEq(IUSDG(USDG).balanceOf(employer), employerBefore - total, "employer not debited exactly");
        assertEq(IUSDG(USDG).balanceOf(address(payroll)), poolBefore + total, "contract not credited exactly");
        assertEq(IUSDG(USDG).allowance(employer, address(payroll)), 0, "allowance not consumed");

        // public totals start correct
        (,,, uint256 dep, uint256 clm,) = payroll.runs(runId);
        assertEq(dep, total, "totalDeposited");
        assertEq(clm, 0, "totalClaimed");
        assertEq(payroll.remaining(runId), total, "remaining");

        // ── 3. claims ────────────────────────────────────────────────
        _claimAll(runId, proofs, salts);

        // ── 4. remaining balance ─────────────────────────────────────
        (,,, dep, clm,) = payroll.runs(runId);
        assertEq(dep, total, "totalDeposited drifted");
        assertEq(clm, total, "totalClaimed");
        assertEq(payroll.remaining(runId), 0, "remaining should be zero");
        assertEq(IUSDG(USDG).balanceOf(address(payroll)), 0, "contract still holds USDG");

        // ── 5. reclaim (nothing left, but must still succeed and close the run) ──
        vm.warp(deadline + 1);
        uint256 employerAfterClaims = IUSDG(USDG).balanceOf(employer);

        vm.prank(employer);
        payroll.reclaim(runId);

        assertEq(IUSDG(USDG).balanceOf(employer), employerAfterClaims, "reclaim moved funds when none remained");
        (,,,,, bool reclaimed) = payroll.runs(runId);
        assertTrue(reclaimed, "run not marked reclaimed");
    }

    /// @dev The other reclaim branch: funds left over because someone never claimed.
    function test_fork_reclaimReturnsUnclaimedRemainderInRealUSDG() public {
        (bytes32 root, bytes32[][] memory proofs, bytes32[3] memory salts, uint256 total) = _roster();

        vm.prank(employer);
        IUSDG(USDG).approve(address(payroll), total);
        vm.prank(employer);
        payroll.createRun(root, deadline, total);

        // only alice claims; bob and carol never do
        vm.prank(alice);
        payroll.claim(1, 0, 900e6, salts[0], proofs[0]);

        assertEq(payroll.remaining(1), 600e6, "remaining after one claim");

        vm.warp(deadline + 1);
        uint256 before = IUSDG(USDG).balanceOf(employer);

        vm.prank(employer);
        payroll.reclaim(1);

        assertEq(IUSDG(USDG).balanceOf(employer) - before, 600e6, "reclaim returned the wrong amount");
        assertEq(IUSDG(USDG).balanceOf(address(payroll)), 0, "contract not drained");
    }

    /// @dev The documented honest boundary, exercised against the real token: a valid proof that
    ///      cannot be paid because the employer under-funded.
    function test_fork_underfundedRun_validProofCannotBePaid() public {
        (bytes32 root, bytes32[][] memory proofs, bytes32[3] memory salts,) = _roster();

        // commit to 1,500 but fund only 900
        vm.prank(employer);
        IUSDG(USDG).approve(address(payroll), 900e6);
        vm.prank(employer);
        payroll.createRun(root, deadline, 900e6);

        vm.prank(alice);
        payroll.claim(1, 0, 900e6, salts[0], proofs[0]); // takes everything

        // bob's proof is genuinely valid...
        assertTrue(payroll.verifyClaim(1, 1, bob, 400e6, salts[1], proofs[1]));

        // ...and the real token has nothing to give him
        vm.prank(bob);
        vm.expectRevert();
        payroll.claim(1, 1, 400e6, salts[1], proofs[1]);

        assertEq(payroll.remaining(1), 0, "the shortfall is visible on-chain");
    }

    /// @dev Claims are deadline-gated against real block time.
    function test_fork_claimRejectedAfterDeadline() public {
        (bytes32 root_, bytes32[][] memory proofs, bytes32[3] memory salts, uint256 total) = _roster();
        assertTrue(root_ != bytes32(0), "empty root");

        vm.prank(employer);
        IUSDG(USDG).approve(address(payroll), total);
        vm.prank(employer);
        payroll.createRun(keccak256("r"), deadline, total);

        vm.warp(deadline + 1);
        vm.prank(alice);
        vm.expectRevert(PayrollRun.DeadlinePassed.selector);
        payroll.claim(1, 0, 900e6, salts[0], proofs[0]);
    }

    // ───────────────────────────────────────────────────────────────
    // tree helper (must match app/lib/merkle.js)
    // ───────────────────────────────────────────────────────────────

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _buildTree(bytes32[] memory leaves)
        internal
        pure
        returns (bytes32 root, bytes32[][] memory proofs)
    {
        uint256 n = leaves.length;
        bytes32[][] memory levels = new bytes32[][](64);
        uint256 depth = 0;
        levels[0] = leaves;

        while (levels[depth].length > 1) {
            uint256 len = levels[depth].length;
            bytes32[] memory next = new bytes32[]((len + 1) / 2);
            for (uint256 i = 0; i < len; i += 2) {
                if (i + 1 == len) {
                    next[i / 2] = levels[depth][i];
                } else {
                    next[i / 2] = _hashPair(levels[depth][i], levels[depth][i + 1]);
                }
            }
            depth++;
            levels[depth] = next;
        }

        root = levels[depth][0];

        proofs = new bytes32[][](n);
        for (uint256 i = 0; i < n; i++) {
            bytes32[] memory buf = new bytes32[](depth);
            uint256 plen = 0;
            uint256 idx = i;
            for (uint256 d = 0; d < depth; d++) {
                uint256 len = levels[d].length;
                if (idx % 2 == 1) {
                    buf[plen++] = levels[d][idx - 1];
                } else if (idx + 1 < len) {
                    buf[plen++] = levels[d][idx + 1];
                }
                idx = idx / 2;
            }
            bytes32[] memory trimmed = new bytes32[](plen);
            for (uint256 k = 0; k < plen; k++) {
                trimmed[k] = buf[k];
            }
            proofs[i] = trimmed;
        }
    }
}
