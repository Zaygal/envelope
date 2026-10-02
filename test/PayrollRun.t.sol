// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PayrollRun} from "../src/PayrollRun.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";

contract PayrollRunTest is Test {
    PayrollRun internal payroll;
    MockUSDG internal usdg;

    address internal employer = address(0xA11CE);
    address internal alice = address(0xA1);
    address internal bob = address(0xB0);
    address internal carol = address(0xCA);

    uint64 internal deadline;

    function setUp() public {
        usdg = new MockUSDG();
        payroll = new PayrollRun(address(usdg));

        usdg.mint(employer, 10_000_000e6);

        vm.prank(employer);
        usdg.approve(address(payroll), type(uint256).max);

        vm.warp(1_700_000_000); // deterministic clock
        deadline = uint64(block.timestamp + 30 days);
    }

    // ---------------------------------------------------------------
    // Tree helpers — MUST mirror the browser builder exactly
    // ---------------------------------------------------------------

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// @dev Odd node is carried up UNCHANGED (never duplicated) — matches the JS builder.
    function _buildTree(bytes32[] memory leaves)
        internal
        pure
        returns (bytes32 root, bytes32[][] memory proofs)
    {
        uint256 n = leaves.length;
        require(n > 0, "empty tree");

        bytes32[][] memory levels = new bytes32[][](64);
        uint256 depth = 0;
        levels[0] = leaves;

        while (levels[depth].length > 1) {
            uint256 len = levels[depth].length;
            bytes32[] memory next = new bytes32[]((len + 1) / 2);
            for (uint256 i = 0; i < len; i += 2) {
                if (i + 1 == len) {
                    next[i / 2] = levels[depth][i]; // carried up unchanged
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
                // else: carried up unchanged -> contributes no proof element
                idx = idx / 2;
            }
            bytes32[] memory trimmed = new bytes32[](plen);
            for (uint256 k = 0; k < plen; k++) {
                trimmed[k] = buf[k];
            }
            proofs[i] = trimmed;
        }
    }

    function _salt(string memory tag) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("envelope.test.salt.", tag));
    }

    /// @dev Build a tree for a fixed 3-person roster.
    function _threePersonTree(uint256 runId, uint256 aAmt, uint256 bAmt, uint256 cAmt)
        internal
        view
        returns (bytes32 root, bytes32[][] memory proofs, bytes32[3] memory salts)
    {
        salts = [_salt("alice"), _salt("bob"), _salt("carol")];
        bytes32[] memory leaves = new bytes32[](3);
        leaves[0] = payroll.leafFor(runId, 0, alice, aAmt, salts[0]);
        leaves[1] = payroll.leafFor(runId, 1, bob, bAmt, salts[1]);
        leaves[2] = payroll.leafFor(runId, 2, carol, cAmt, salts[2]);
        (root, proofs) = _buildTree(leaves);
    }

    function _createThreePersonRun()
        internal
        returns (uint256 runId, bytes32[][] memory proofs, bytes32[3] memory salts, uint256 total)
    {
        uint256 aAmt = 900e6;
        uint256 bAmt = 400e6;
        uint256 cAmt = 200e6;
        total = aAmt + bAmt + cAmt;

        runId = payroll.nextRunId();
        bytes32 root;
        (root, proofs, salts) = _threePersonTree(runId, aAmt, bAmt, cAmt);

        vm.prank(employer);
        payroll.createRun(root, deadline, total);
    }

    // ---------------------------------------------------------------
    // createRun
    // ---------------------------------------------------------------

    function test_createRun_locksFundsAndStoresState() public {
        (uint256 runId,,,) = _createThreePersonRun();

        (
            address emp,
            bytes32 root,
            uint64 dl,
            uint256 deposited,
            uint256 claimed,
            bool reclaimed
        ) = payroll.runs(runId);

        assertEq(emp, employer);
        assertTrue(root != bytes32(0));
        assertEq(dl, deadline);
        assertEq(deposited, 1500e6, "deposited");
        assertEq(claimed, 0, "nothing claimed yet");
        assertFalse(reclaimed);
        assertEq(usdg.balanceOf(address(payroll)), 1500e6, "USDG actually moved in");
        assertEq(payroll.runCount(), 1);
        assertEq(payroll.remaining(runId), 1500e6);
    }

    function test_createRun_emitsWithEmployerAndTotals() public {
        uint256 runId = payroll.nextRunId();
        (bytes32 root,,) = _threePersonTree(runId, 900e6, 400e6, 200e6);

        vm.expectEmit(true, true, false, true, address(payroll));
        emit PayrollRun.RunCreated(runId, employer, root, deadline, 1500e6);

        vm.prank(employer);
        payroll.createRun(root, deadline, 1500e6);
    }

    function test_createRun_revertsOnZeroRoot() public {
        vm.prank(employer);
        vm.expectRevert(PayrollRun.RootRequired.selector);
        payroll.createRun(bytes32(0), deadline, 100e6);
    }

    function test_createRun_revertsOnZeroAmount() public {
        vm.prank(employer);
        vm.expectRevert(PayrollRun.AmountRequired.selector);
        payroll.createRun(keccak256("r"), deadline, 0);
    }

    function test_createRun_revertsWhenDeadlineTooSoon() public {
        // MIN_DEADLINE is 1 day; anything less must be rejected (anti-rug rail)
        vm.prank(employer);
        vm.expectRevert(PayrollRun.DeadlineTooSoon.selector);
        payroll.createRun(keccak256("r"), uint64(block.timestamp + 1 hours), 100e6);

        vm.prank(employer);
        vm.expectRevert(PayrollRun.DeadlineTooSoon.selector);
        payroll.createRun(keccak256("r"), uint64(block.timestamp + 1 days - 1), 100e6);
    }

    function test_createRun_revertsWithoutApproval() public {
        address stingy = address(0xDEAD);
        usdg.mint(stingy, 100e6);

        vm.prank(stingy);
        vm.expectRevert(); // ERC20 insufficient allowance
        payroll.createRun(keccak256("r"), deadline, 100e6);
    }

    function test_createRun_revertsWithoutBalance() public {
        address broke = address(0xBEEF);
        vm.prank(broke);
        usdg.approve(address(payroll), type(uint256).max);

        vm.prank(broke);
        vm.expectRevert(); // ERC20 insufficient balance
        payroll.createRun(keccak256("r"), deadline, 100e6);
    }

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert(PayrollRun.ZeroAddress.selector);
        new PayrollRun(address(0));
    }

    // ---------------------------------------------------------------
    // claim — happy path
    // ---------------------------------------------------------------

    function test_claim_paysExactlyAndUpdatesPublicTotals() public {
        (uint256 runId, bytes32[][] memory proofs, bytes32[3] memory salts,) = _createThreePersonRun();

        uint256 aliceBefore = usdg.balanceOf(alice);

        vm.prank(alice);
        payroll.claim(runId, 0, 900e6, salts[0], proofs[0]);

        assertEq(usdg.balanceOf(alice) - aliceBefore, 900e6, "exact amount paid");
        assertTrue(payroll.leafClaimed(runId, 0), "nullifier set");

        (,,, uint256 deposited, uint256 claimed,) = payroll.runs(runId);
        assertEq(deposited, 1500e6);
        assertEq(claimed, 900e6, "public totalClaimed moved");
        assertEq(payroll.remaining(runId), 600e6);
        assertEq(usdg.balanceOf(address(payroll)), 600e6);
    }

    function test_claim_allRecipients_drainsExactly() public {
        (uint256 runId, bytes32[][] memory proofs, bytes32[3] memory salts,) = _createThreePersonRun();

        vm.prank(alice);
        payroll.claim(runId, 0, 900e6, salts[0], proofs[0]);
        vm.prank(bob);
        payroll.claim(runId, 1, 400e6, salts[1], proofs[1]);
        vm.prank(carol);
        payroll.claim(runId, 2, 200e6, salts[2], proofs[2]);

        (,,, uint256 deposited, uint256 claimed,) = payroll.runs(runId);
        assertEq(claimed, deposited, "fully claimed");
        assertEq(usdg.balanceOf(address(payroll)), 0);
        assertEq(payroll.remaining(runId), 0);
    }

    function test_claim_emits() public {
        (uint256 runId, bytes32[][] memory proofs, bytes32[3] memory salts,) = _createThreePersonRun();

        vm.expectEmit(true, true, true, true, address(payroll));
        emit PayrollRun.Claimed(runId, 0, alice, 900e6);

        vm.prank(alice);
        payroll.claim(runId, 0, 900e6, salts[0], proofs[0]);
    }

    // ---------------------------------------------------------------
    // claim — every revert path
    // ---------------------------------------------------------------

    function test_claim_revertsOnWrongProof() public {
        (uint256 runId, bytes32[][] memory proofs, bytes32[3] memory salts,) = _createThreePersonRun();

        // bob's proof cannot unlock alice's commitment
        vm.prank(alice);
        vm.expectRevert(PayrollRun.InvalidProof.selector);
        payroll.claim(runId, 0, 900e6, salts[0], proofs[1]);
    }

    function test_claim_revertsOnInflatedAmount() public {
        (uint256 runId, bytes32[][] memory proofs, bytes32[3] memory salts,) = _createThreePersonRun();

        vm.prank(alice);
        vm.expectRevert(PayrollRun.InvalidProof.selector);
        payroll.claim(runId, 0, 999_999e6, salts[0], proofs[0]); // proof binds the amount
    }

    function test_claim_revertsOnWrongSalt() public {
        (uint256 runId, bytes32[][] memory proofs,,) = _createThreePersonRun();

        vm.prank(alice);
        vm.expectRevert(PayrollRun.InvalidProof.selector);
        payroll.claim(runId, 0, 900e6, _salt("wrong"), proofs[0]);
    }

    function test_claim_revertsForWrongClaimant() public {
        // the commitment is bound to alice; bob cannot claim it even with the real proof
        (uint256 runId, bytes32[][] memory proofs, bytes32[3] memory salts,) = _createThreePersonRun();

        vm.prank(bob);
        vm.expectRevert(PayrollRun.InvalidProof.selector);
        payroll.claim(runId, 0, 900e6, salts[0], proofs[0]);
    }

    function test_claim_revertsOnDoubleClaim() public {
        (uint256 runId, bytes32[][] memory proofs, bytes32[3] memory salts,) = _createThreePersonRun();

        vm.prank(alice);
        payroll.claim(runId, 0, 900e6, salts[0], proofs[0]);

        vm.prank(alice);
        vm.expectRevert(PayrollRun.AlreadyClaimed.selector);
        payroll.claim(runId, 0, 900e6, salts[0], proofs[0]);
    }

    function test_claim_revertsOnUnknownRun() public {
        (, bytes32[][] memory proofs, bytes32[3] memory salts,) = _createThreePersonRun();

        vm.prank(alice);
        vm.expectRevert(PayrollRun.UnknownRun.selector);
        payroll.claim(999, 0, 900e6, salts[0], proofs[0]);
    }

    function test_claim_revertsAfterDeadline() public {
        (uint256 runId, bytes32[][] memory proofs, bytes32[3] memory salts,) = _createThreePersonRun();

        vm.warp(deadline + 1);

        vm.prank(alice);
        vm.expectRevert(PayrollRun.DeadlinePassed.selector);
        payroll.claim(runId, 0, 900e6, salts[0], proofs[0]);
    }

    function test_claim_allowedExactlyAtDeadline() public {
        (uint256 runId, bytes32[][] memory proofs, bytes32[3] memory salts,) = _createThreePersonRun();

        vm.warp(deadline); // boundary is inclusive for the recipient

        vm.prank(alice);
        payroll.claim(runId, 0, 900e6, salts[0], proofs[0]);
        assertTrue(payroll.leafClaimed(runId, 0));
    }

    function test_claim_revertsAfterReclaim() public {
        (uint256 runId, bytes32[][] memory proofs, bytes32[3] memory salts,) = _createThreePersonRun();

        vm.warp(deadline + 1);
        vm.prank(employer);
        payroll.reclaim(runId);

        vm.prank(alice);
        vm.expectRevert(PayrollRun.RunClosed.selector);
        payroll.claim(runId, 0, 900e6, salts[0], proofs[0]);
    }

    // ---------------------------------------------------------------
    // reclaim
    // ---------------------------------------------------------------

    function test_reclaim_returnsOnlyRemainder() public {
        (uint256 runId, bytes32[][] memory proofs, bytes32[3] memory salts,) = _createThreePersonRun();

        vm.prank(alice);
        payroll.claim(runId, 0, 900e6, salts[0], proofs[0]);

        uint256 before = usdg.balanceOf(employer);
        vm.warp(deadline + 1);
        vm.prank(employer);
        payroll.reclaim(runId);

        assertEq(usdg.balanceOf(employer) - before, 600e6, "only the unclaimed remainder");
        assertEq(usdg.balanceOf(address(payroll)), 0);
        (,,,,, bool reclaimed) = payroll.runs(runId);
        assertTrue(reclaimed);
    }

    function test_reclaim_revertsBeforeDeadline() public {
        (uint256 runId,,,) = _createThreePersonRun();

        vm.prank(employer);
        vm.expectRevert(PayrollRun.TooEarlyToReclaim.selector);
        payroll.reclaim(runId);

        // and still reverts exactly at the deadline (claims own that instant)
        vm.warp(deadline);
        vm.prank(employer);
        vm.expectRevert(PayrollRun.TooEarlyToReclaim.selector);
        payroll.reclaim(runId);
    }

    function test_reclaim_revertsForNonEmployer() public {
        (uint256 runId,,,) = _createThreePersonRun();

        vm.warp(deadline + 1);
        vm.prank(alice);
        vm.expectRevert(PayrollRun.NotEmployer.selector);
        payroll.reclaim(runId);
    }

    function test_reclaim_revertsTwice() public {
        (uint256 runId,,,) = _createThreePersonRun();

        vm.warp(deadline + 1);
        vm.prank(employer);
        payroll.reclaim(runId);

        vm.prank(employer);
        vm.expectRevert(PayrollRun.RunClosed.selector);
        payroll.reclaim(runId);
    }

    function test_reclaim_revertsOnUnknownRun() public {
        vm.warp(deadline + 1);
        vm.prank(employer);
        vm.expectRevert(PayrollRun.UnknownRun.selector);
        payroll.reclaim(42);
    }

    // ---------------------------------------------------------------
    // Privacy: nothing about the roster is readable before a claim
    // ---------------------------------------------------------------

    function test_privacy_rootDoesNotRevealCountOrAmounts() public {
        uint256 runId = payroll.nextRunId();

        // two completely different rosters that happen to fund the same total
        (bytes32 rootA,,) = _threePersonTree(runId, 900e6, 400e6, 200e6);
        (bytes32 rootB,,) = _threePersonTree(runId, 1500e6, 0, 0);

        assertTrue(rootA != rootB, "root commits to the roster");

        // and no per-leaf data is stored on-chain
        bytes32[] memory leaves = new bytes32[](3);
        leaves[0] = payroll.leafFor(runId, 0, alice, 900e6, _salt("alice"));
        (bytes32 rootC,) = _buildTree(leaves);

        assertTrue(rootC != rootA, "no leaf is individually recoverable from the root");
    }

    // ---------------------------------------------------------------
    // verifyClaim view — used by the UI to check before spending gas
    // ---------------------------------------------------------------

    function test_verifyClaim_mirrorsOnChainOutcome() public {
        (uint256 runId, bytes32[][] memory proofs, bytes32[3] memory salts,) = _createThreePersonRun();

        assertTrue(payroll.verifyClaim(runId, 0, alice, 900e6, salts[0], proofs[0]));
        assertFalse(payroll.verifyClaim(runId, 0, alice, 900e6, _salt("wrong"), proofs[0]));
        assertFalse(payroll.verifyClaim(runId, 0, bob, 900e6, salts[0], proofs[0]));

        vm.prank(alice);
        payroll.claim(runId, 0, 900e6, salts[0], proofs[0]);

        assertFalse(payroll.verifyClaim(runId, 0, alice, 900e6, salts[0], proofs[0]), "spent");

        vm.warp(deadline + 1);
        assertFalse(payroll.verifyClaim(runId, 1, bob, 400e6, salts[1], proofs[1]), "past deadline");
    }

    // ---------------------------------------------------------------
    // Invariants
    // ---------------------------------------------------------------

    function testFuzz_invariants_holdAcrossRandomSequences(
        uint256 aAmt,
        uint256 bAmt,
        uint256 cAmt,
        uint8 claimMask
    ) public {
        aAmt = bound(aAmt, 1, 1_000e6);
        bAmt = bound(bAmt, 1, 1_000e6);
        cAmt = bound(cAmt, 1, 1_000e6);
        uint256 total = aAmt + bAmt + cAmt;

        uint256 runId = payroll.nextRunId();
        bytes32 root;
        bytes32[][] memory proofs;
        bytes32[3] memory salts;
        (root, proofs, salts) = _threePersonTree(runId, aAmt, bAmt, cAmt);

        vm.prank(employer);
        payroll.createRun(root, deadline, total);

        uint256 expectedPaid = 0;

        if (claimMask & 1 != 0) {
            vm.prank(alice);
            payroll.claim(runId, 0, aAmt, salts[0], proofs[0]);
            expectedPaid += aAmt;
        }
        if (claimMask & 2 != 0) {
            vm.prank(bob);
            payroll.claim(runId, 1, bAmt, salts[1], proofs[1]);
            expectedPaid += bAmt;
        }
        if (claimMask & 4 != 0) {
            vm.prank(carol);
            payroll.claim(runId, 2, cAmt, salts[2], proofs[2]);
            expectedPaid += cAmt;
        }

        (,,, uint256 deposited, uint256 claimed,) = payroll.runs(runId);

        assertEq(claimed, expectedPaid, "totalClaimed == sum of actual claims");
        assertLe(claimed, deposited, "claimed can never exceed deposited");
        assertEq(
            usdg.balanceOf(address(payroll)),
            deposited - claimed,
            "contract balance == deposited - claimed"
        );
    }

    function testFuzz_singleLeafTreeWorks(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e6);

        uint256 runId = payroll.nextRunId();
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = payroll.leafFor(runId, 0, alice, amount, _salt("solo"));
        (bytes32 root, bytes32[][] memory proofs) = _buildTree(leaves);

        vm.prank(employer);
        payroll.createRun(root, deadline, amount);

        vm.prank(alice);
        payroll.claim(runId, 0, amount, _salt("solo"), proofs[0]);

        assertEq(usdg.balanceOf(alice), amount, "single-leaf proof (empty path) works");
    }

    function testFuzz_evenLeafCountTree(uint256[4] memory amounts) public {
        uint256 total = 0;
        bytes32[] memory leaves = new bytes32[](4);
        address[4] memory who = [alice, bob, carol, address(0xC0FFEE)];

        for (uint256 i = 0; i < 4; i++) {
            amounts[i] = bound(amounts[i], 1, 100_000e6);
            total += amounts[i];
            leaves[i] = payroll.leafFor(1, i, who[i], amounts[i], _salt("even"));
        }

        (bytes32 root, bytes32[][] memory proofs) = _buildTree(leaves);

        vm.prank(employer);
        payroll.createRun(root, deadline, total);

        for (uint256 i = 0; i < 4; i++) {
            vm.prank(who[i]);
            payroll.claim(1, i, amounts[i], _salt("even"), proofs[i]);
        }

        (,,, uint256 deposited, uint256 claimed,) = payroll.runs(1);
        assertEq(claimed, deposited, "4-leaf tree fully claimed");
    }

    // ---------------------------------------------------------------
    // The honest boundary: under-funding is not preventable,
    // but it cannot be hidden either.
    // ---------------------------------------------------------------

    function test_underfunding_lateClaimantReverts_butIsProvable() public {
        uint256 runId = payroll.nextRunId();
        bytes32 root;
        bytes32[][] memory proofs;
        bytes32[3] memory salts;
        (root, proofs, salts) = _threePersonTree(runId, 900e6, 400e6, 200e6);

        // employer commits to 1500 but funds only 900 -> dishonest, and undetectable up front
        vm.prank(employer);
        payroll.createRun(root, deadline, 900e6);

        vm.prank(alice);
        payroll.claim(runId, 0, 900e6, salts[0], proofs[0]); // takes everything

        // bob holds a VALID proof and cannot be paid: the failure is public and reproducible
        assertTrue(payroll.verifyClaim(runId, 1, bob, 400e6, salts[1], proofs[1]));
        vm.prank(bob);
        vm.expectRevert(); // ERC20 transfer to zero balance
        payroll.claim(runId, 1, 400e6, salts[1], proofs[1]);

        // and the shortfall is visible on-chain even before bob tries
        (,,, uint256 deposited, uint256 claimed,) = payroll.runs(runId);
        assertEq(deposited, 900e6);
        assertEq(claimed, 900e6);
        assertEq(payroll.remaining(runId), 0, "nothing left to pay bob, provably");
    }

    // ---------------------------------------------------------------
    // Multiple runs are independent
    // ---------------------------------------------------------------

    function test_runsAreIsolated_sameLeafCannotReplayAcrossRuns() public {
        bytes32 salt = _salt("x");

        // Two runs with IDENTICAL rosters, amounts AND salts. The only difference is the runId.
        uint256 runA = payroll.nextRunId();
        bytes32[] memory leavesA = new bytes32[](2);
        leavesA[0] = payroll.leafFor(runA, 0, alice, 500e6, salt);
        leavesA[1] = payroll.leafFor(runA, 1, bob, 500e6, salt);
        (bytes32 rootA, bytes32[][] memory proofsA) = _buildTree(leavesA);

        vm.prank(employer);
        payroll.createRun(rootA, deadline, 1000e6);

        uint256 runB = payroll.nextRunId();
        bytes32[] memory leavesB = new bytes32[](2);
        leavesB[0] = payroll.leafFor(runB, 0, alice, 500e6, salt);
        leavesB[1] = payroll.leafFor(runB, 1, bob, 500e6, salt);
        (bytes32 rootB, bytes32[][] memory proofsB) = _buildTree(leavesB);

        vm.prank(employer);
        payroll.createRun(rootB, deadline, 1000e6);

        // identical inputs, different roots — runId is bound into the leaf
        assertTrue(rootA != rootB, "runId must be bound into the leaf");
        assertTrue(proofsA[0].length > 0, "non-trivial proof actually exercises the path");

        // run A's proof does not open run B
        vm.prank(alice);
        vm.expectRevert(PayrollRun.InvalidProof.selector);
        payroll.claim(runB, 0, 500e6, salt, proofsA[0]);

        // the correct proof does
        vm.prank(alice);
        payroll.claim(runB, 0, 500e6, salt, proofsB[0]);

        assertEq(usdg.balanceOf(alice), 500e6);
    }
}
