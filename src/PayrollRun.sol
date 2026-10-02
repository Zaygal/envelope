// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Envelope — verifiable payroll totals, private roster.
 *
 * @notice An employer commits to a payroll as a Merkle root of salted commitments and funds the
 *         contract up front. Anyone can then verify how much was set aside (`totalDeposited`) and
 *         how much has actually been paid out (`totalClaimed`). Individual salaries are never
 *         published: they live only as salted hashes in the tree, and there is no per-leaf storage
 *         on-chain, so the roster cannot be enumerated by an outside observer.
 *
 * @notice WHAT THIS DOES NOT DO (stated plainly, because it is the honest boundary):
 *         The contract CANNOT prove that the committed salaries add up to `totalDeposited`. An
 *         employer may under-fund, in which case a recipient holding a perfectly valid proof has
 *         their `claim()` revert on insufficient balance. Preventing that requires a sum proof
 *         (e.g. Pedersen commitments), which is out of scope by design. What *is* guaranteed:
 *         the root is fixed before any money moves, the funds are already in the contract, the
 *         contract pays exactly the committed amount to exactly the committed address, and a
 *         shortfall cannot be hidden — an unpaid recipient can demonstrate a valid proof that
 *         reverts, which is public, verifiable evidence of non-payment.
 *
 * @notice AMOUNTS ARE REVEALED WHEN CLAIMED. The contract must receive `amount` to transfer it, so
 *         a claim puts that one recipient and amount on-chain. This is inherent without ZK.
 */
contract PayrollRun is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Domain separator for leaf hashing. Prevents a leaf being confused with an internal node.
    bytes32 public constant LEAF_TAG = keccak256("Envelope.PayrollRun.leaf.v1");

    /// @notice Minimum notice before an employer may reclaim. Blocks a 1-block "rug" deadline.
    uint64 public constant MIN_DEADLINE = 1 days;

    /// @notice The settlement asset. USDG (6 decimals on Arbitrum Sepolia).
    IERC20 public immutable usdg;

    struct Run {
        address employer;      // who created and funded the run
        bytes32 root;          // Merkle root over salted salary commitments
        uint64  deadline;      // claims open until here; after this only the employer may reclaim
        uint256 totalDeposited; // USDG funded in   (public, on-chain fact)
        uint256 totalClaimed;   // USDG paid out     (public, on-chain fact)
        bool    reclaimed;     // true once the employer has closed the run
    }

    /// @notice Runs are 1-indexed; 0 is reserved as "no run".
    uint256 public nextRunId = 1;

    mapping(uint256 => Run) public runs;

    /// @notice Nullifier: runId => leaf index => claimed. Prevents double claims.
    mapping(uint256 => mapping(uint256 => bool)) public leafClaimed;

    event RunCreated(
        uint256 indexed runId,
        address indexed employer,
        bytes32 root,
        uint64 deadline,
        uint256 totalDeposited
    );
    event Claimed(uint256 indexed runId, uint256 indexed leafIndex, address indexed recipient, uint256 amount);
    event Reclaimed(uint256 indexed runId, address indexed employer, uint256 amount);

    error ZeroAddress();
    error RootRequired();
    error AmountRequired();
    error DeadlineTooSoon();
    error UnknownRun();
    error RunClosed();
    error DeadlinePassed();
    error AlreadyClaimed();
    error InvalidProof();
    error NotEmployer();
    error TooEarlyToReclaim();

    constructor(address usdg_) {
        if (usdg_ == address(0)) revert ZeroAddress();
        usdg = IERC20(usdg_);
    }

    // ---------------------------------------------------------------------
    // Employer
    // ---------------------------------------------------------------------

    /**
     * @notice Create a funded payroll run.
     * @param root   Merkle root over the salted salary commitments.
     * @param deadline Unix timestamp after which claims close and reclaim opens.
     * @param amount USDG to deposit (in the token's own decimals — 6 for USDG).
     * @return runId The new run's identifier.
     */
    function createRun(bytes32 root, uint64 deadline, uint256 amount)
        external
        nonReentrant
        returns (uint256 runId)
    {
        if (root == bytes32(0)) revert RootRequired();
        if (amount == 0) revert AmountRequired();
        if (deadline < block.timestamp + MIN_DEADLINE) revert DeadlineTooSoon();

        runId = nextRunId++;
        runs[runId] = Run({
            employer: msg.sender,
            root: root,
            deadline: deadline,
            totalDeposited: amount,
            totalClaimed: 0,
            reclaimed: false
        });

        // Effects are complete before the external call.
        emit RunCreated(runId, msg.sender, root, deadline, amount);

        usdg.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Reclaim the unclaimed remainder after the deadline. Closes the run permanently.
     * @dev The employer cannot touch committed funds before the deadline.
     */
    function reclaim(uint256 runId) external nonReentrant {
        Run storage r = runs[runId];
        if (r.employer == address(0)) revert UnknownRun();
        if (msg.sender != r.employer) revert NotEmployer();
        if (block.timestamp <= r.deadline) revert TooEarlyToReclaim();
        if (r.reclaimed) revert RunClosed();

        uint256 amount = r.totalDeposited - r.totalClaimed;
        r.reclaimed = true;

        emit Reclaimed(runId, r.employer, amount);

        if (amount > 0) {
            usdg.safeTransfer(r.employer, amount);
        }
    }

    // ---------------------------------------------------------------------
    // Recipient
    // ---------------------------------------------------------------------

    /**
     * @notice Claim a committed salary. Callable only by the address the commitment was made to.
     * @dev The claimant is `msg.sender`, so it is bound into the leaf: a leaked claim package can
     *      only ever push funds to the rightful recipient, never to a thief.
     * @param runId The run to claim from.
     * @param index The leaf index of this recipient.
     * @param amount The committed amount (USDG base units).
     * @param salt The 32-byte salt generated client-side by the employer.
     * @param proof The Merkle proof for this leaf.
     */
    function claim(
        uint256 runId,
        uint256 index,
        uint256 amount,
        bytes32 salt,
        bytes32[] calldata proof
    ) external nonReentrant {
        Run storage r = runs[runId];
        if (r.employer == address(0)) revert UnknownRun();
        if (r.reclaimed) revert RunClosed();
        if (block.timestamp > r.deadline) revert DeadlinePassed();
        if (leafClaimed[runId][index]) revert AlreadyClaimed();
        if (!MerkleProof.verify(proof, r.root, leafFor(runId, index, msg.sender, amount, salt))) {
            revert InvalidProof();
        }

        // Effects before interaction (plus ReentrancyGuard).
        leafClaimed[runId][index] = true;
        r.totalClaimed += amount;

        emit Claimed(runId, index, msg.sender, amount);

        usdg.safeTransfer(msg.sender, amount);
    }

    // ---------------------------------------------------------------------
    // Views — used by the UI to verify locally before spending gas
    // ---------------------------------------------------------------------

    /// @notice Canonical leaf hash. Exposed so the off-chain builder can be checked against it.
    function leafFor(uint256 runId, uint256 index, address claimant, uint256 amount, bytes32 salt)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(LEAF_TAG, runId, index, claimant, amount, salt));
    }

    /// @notice True if `claimant` could successfully claim right now. Reverts nothing.
    function verifyClaim(
        uint256 runId,
        uint256 index,
        address claimant,
        uint256 amount,
        bytes32 salt,
        bytes32[] calldata proof
    ) external view returns (bool) {
        Run storage r = runs[runId];
        if (r.employer == address(0) || r.reclaimed || block.timestamp > r.deadline) return false;
        if (leafClaimed[runId][index]) return false;
        return MerkleProof.verify(proof, r.root, leafFor(runId, index, claimant, amount, salt));
    }

    /// @notice USDG still held for a run (deposited minus already claimed).
    function remaining(uint256 runId) external view returns (uint256) {
        Run storage r = runs[runId];
        return r.totalDeposited - r.totalClaimed;
    }

    /// @notice Total number of runs ever created.
    function runCount() external view returns (uint256) {
        return nextRunId - 1;
    }
}
