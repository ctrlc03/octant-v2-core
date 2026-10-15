// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { BaseAllocationMechanism, AllocationConfig } from "src/mechanisms/BaseAllocationMechanism.sol";
import { TokenizedAllocationMechanism } from "src/mechanisms/TokenizedAllocationMechanism.sol";
import { IInterfold, IE3RefundManager, ICRISPProgram, CrispCreditMode, CrispCensusMode } from "src/interfaces/IInterfoldCrisp.sol";

/**
 * @title CRISP Allocation Mechanism
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Private, coercion-resistant allocation: ballots are encrypted under an Interfold committee
 *         key and only the per-project totals are ever decrypted.
 * @dev Signup, proposals, share minting, timelock and redemption are the shared
 *      TokenizedAllocationMechanism flow. Only voting differs:
 *
 *      1. Signup and proposing run until `openRound`. `openRound` freezes both, maps every live
 *         proposal to a CRISP option index, and requests an E3 whose input window is
 *         [votingStartTime, votingEndTime].
 *      2. Voters never call `castVote`: it would publish the voter, project and weight. They send
 *         encrypted ballots to CRISPProgram, which reads their voting power back from this
 *         contract (`getPastVotes`) because the round uses `CensusMode.ONCHAIN`. A ballot splits
 *         `votingPower / votingPowerDivisor` credits linearly across projects; a voter can re-vote,
 *         and only the latest ballot counts.
 *      3. After the committee publishes the decrypted tally, `finalizeVoteTally` pulls it in.
 *         A project's shares are its credits times the divisor, so the pool is distributed pro rata
 *         to the credits each project received.
 *
 *      Interfold does not call back into the requester, so finalization pulls the result. If the
 *      E3 fails, finalization succeeds with an empty tally: every proposal is Defeated and the owner
 *      can sweep the pool after the grace period, and `claimFeeRefund` returns the fee to its payer.
 *
 *      Funding is linear (proportional to credits), not quadratic: the stock CRISP circuit only
 *      bounds the sum of a ballot's weights, so it cannot enforce a quadratic cost.
 */
contract CrispAllocationMechanism is BaseAllocationMechanism {
    using SafeERC20 for IERC20;

    /// @notice Largest option count the CRISP circuit accepts
    uint256 public constant MAX_OPTIONS = 10;

    /// @notice Parameters chosen when the round is opened
    /// @param committeeSize Interfold committee size tier
    /// @param paramSet BFV parameter set index
    /// @param expectedCryptoConfigId Circuit configuration accepted for the E3
    /// @param computeProviderParams Opaque compute provider parameters
    /// @param votingPowerDivisor Voting power (18 decimals) per ballot credit; also the minimum
    ///        voting power needed to vote
    /// @param maxFee Maximum Interfold fee the caller accepts, in fee token units
    struct RoundParams {
        IInterfold.CommitteeSize committeeSize;
        uint8 paramSet;
        bytes32 expectedCryptoConfigId;
        bytes computeProviderParams;
        uint256 votingPowerDivisor;
        uint256 maxFee;
    }

    // ============================================
    // ERRORS
    // ============================================

    error ZeroAddress();
    error NotRoundOperator(address caller);
    error RoundAlreadyOpened();
    error RoundNotOpened();
    error VotingAlreadyStarted(uint256 currentTime, uint256 votingStartTime);
    error SignupInCurrentBlock();
    error ZeroVotingPowerDivisor();
    error InvalidOptionCount(uint256 count);
    error FeeAboveMax(uint256 fee, uint256 maxFee);
    error UnknownTimepoint(uint256 timepoint);
    error EncryptedBallotsOnly();
    error ZeroAddressCannotPropose();
    error E3NotFailed(IInterfold.E3Stage stage);

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when the CRISP round is requested
    /// @param e3Id Interfold E3 identifier
    /// @param optionPids Proposal id behind each option index
    /// @param inputStart Start of the ballot window
    /// @param inputEnd End of the ballot window
    /// @param votingPowerDivisor Voting power per ballot credit
    /// @param fee Interfold fee paid
    event CrispRoundOpened(
        uint256 indexed e3Id,
        uint256[] optionPids,
        uint256 inputStart,
        uint256 inputEnd,
        uint256 votingPowerDivisor,
        uint256 fee
    );

    /// @notice Emitted when the decrypted tally is applied during finalization
    /// @param e3Id Interfold E3 identifier
    /// @param optionPids Proposal id behind each option index
    /// @param credits Total ballot credits per option
    event CrispTallyApplied(uint256 indexed e3Id, uint256[] optionPids, uint256[] credits);

    /// @notice Emitted when finalization proceeds without a tally because the E3 failed
    /// @param e3Id Interfold E3 identifier
    event CrispRoundFailed(uint256 indexed e3Id);

    /// @notice Emitted when an E3 fee refund is forwarded to the account that paid the fee
    /// @param e3Id Interfold E3 identifier
    /// @param payer Recipient of the refund
    /// @param amount Refunded amount, in the E3's fee token
    event CrispFeeRefunded(uint256 indexed e3Id, address indexed payer, uint256 amount);

    // ============================================
    // STATE
    // ============================================

    /// @notice Interfold core contract
    IInterfold public immutable interfold;

    /// @notice CRISPProgram registered with `interfold`
    address public immutable crispProgram;

    /// @notice E3 identifier of the round (0 until opened)
    uint256 public e3Id;

    /// @notice True once `openRound` has requested the E3
    bool public roundOpened;

    /// @notice Timepoint CRISP reads voting power at (`clock() - 1` in the opening block)
    uint48 public censusSnapshot;

    /// @notice Sum of all voting power at the snapshot
    uint256 public censusTotalPower;

    /// @notice Voting power per ballot credit
    uint256 public votingPowerDivisor;

    /// @notice Account that paid the Interfold fee and receives any refund
    address public feePayer;

    /// @notice Fee token the E3 was paid in
    IERC20 public roundFeeToken;

    /// @notice Total ballot credits each proposal received (set at finalization)
    mapping(uint256 pid => uint256 credits) public creditsOf;

    /// @dev Timestamp of the latest signup; a round cannot open in the same block
    uint256 internal _lastSignupAt;

    /// @dev Proposal id behind each CRISP option index
    uint256[] internal _optionPids;

    /// @dev Every address that signed up, to total the census when the round opens
    address[] internal _voters;
    mapping(address => bool) internal _isVoter;

    /**
     * @notice Deploy the mechanism
     * @param _implementation Shared TokenizedAllocationMechanism implementation
     * @param _config Allocation configuration
     * @param _interfold Interfold core contract
     * @param _crispProgram CRISPProgram registered with `_interfold`
     */
    constructor(
        address _implementation,
        AllocationConfig memory _config,
        IInterfold _interfold,
        address _crispProgram
    ) BaseAllocationMechanism(_implementation, _config) {
        if (address(_interfold) == address(0) || _crispProgram == address(0)) revert ZeroAddress();
        interfold = _interfold;
        crispProgram = _crispProgram;
    }

    // ============================================
    // ROUND
    // ============================================

    /**
     * @notice Freeze signups and proposals and request the CRISP round
     * @dev Callable by keeper or management, at or before `votingStartTime`, and not in a block that
     *      contained a signup: CRISP snapshots voting power at `block.timestamp - 1`.
     *      Pulls the Interfold fee from the caller in the Interfold fee token.
     *      Requires 2..10 live proposals.
     * @param p Round parameters
     * @return id Interfold E3 identifier
     */
    function openRound(RoundParams calldata p) external returns (uint256 id) {
        TokenizedAllocationMechanism tam = _tokenizedAllocation();
        if (msg.sender != tam.keeper() && msg.sender != tam.management()) revert NotRoundOperator(msg.sender);
        if (roundOpened) revert RoundAlreadyOpened();

        uint256 inputStart = tam.votingStartTime();
        if (block.timestamp > inputStart) revert VotingAlreadyStarted(block.timestamp, inputStart);
        if (_lastSignupAt >= block.timestamp) revert SignupInCurrentBlock();
        if (p.votingPowerDivisor == 0) revert ZeroVotingPowerDivisor();

        uint256 proposalCount = _getProposalCount();
        for (uint256 pid = 1; pid <= proposalCount; ++pid) {
            if (!_getProposal(pid).canceled) _optionPids.push(pid);
        }
        uint256 numOptions = _optionPids.length;
        if (numOptions < 2 || numOptions > MAX_OPTIONS) revert InvalidOptionCount(numOptions);

        // Effects before the request: CRISPProgram.validate calls back into the census views below.
        roundOpened = true;
        censusSnapshot = uint48(block.timestamp - 1);
        censusTotalPower = _totalVotingPower();
        votingPowerDivisor = p.votingPowerDivisor;
        feePayer = msg.sender;
        IERC20 feeToken = interfold.feeToken();
        roundFeeToken = feeToken;

        IInterfold.E3RequestParams memory params = _buildRequestParams(
            p,
            [inputStart, tam.votingEndTime()],
            numOptions,
            feeToken
        );
        uint256 fee = interfold.getE3Quote(params);
        if (fee > p.maxFee) revert FeeAboveMax(fee, p.maxFee);
        params.maxFee = fee;

        feeToken.safeTransferFrom(msg.sender, address(this), fee);
        feeToken.forceApprove(address(interfold), fee);
        id = interfold.request(params);
        e3Id = id;

        emit CrispRoundOpened(id, _optionPids, params.inputWindow[0], params.inputWindow[1], p.votingPowerDivisor, fee);
    }

    /// @dev Sum of every registered voter's power
    function _totalVotingPower() internal view returns (uint256 total) {
        uint256 voterCount = _voters.length;
        for (uint256 i; i < voterCount; ++i) {
            total += _getVotingPower(_voters[i]);
        }
    }

    /// @dev E3 request for a CUSTOM-credit, ONCHAIN-census CRISP round whose votes token is this contract
    function _buildRequestParams(
        RoundParams calldata p,
        uint256[2] memory inputWindow,
        uint256 numOptions,
        IERC20 feeToken
    ) internal view returns (IInterfold.E3RequestParams memory) {
        bytes memory customParams = abi.encode(
            address(this), // votes token: this contract answers getPastVotes / getPastTotalSupply
            p.votingPowerDivisor, // minimum voting power: at least one credit
            numOptions,
            CrispCreditMode.CUSTOM,
            uint256(0), // credits: unused in CUSTOM mode
            CrispCensusMode.ONCHAIN,
            p.votingPowerDivisor
        );
        return
            IInterfold.E3RequestParams({
                committeeSize: p.committeeSize,
                inputWindow: inputWindow,
                e3Program: crispProgram,
                paramSet: p.paramSet,
                computeProviderParams: p.computeProviderParams,
                customParams: customParams,
                expectedFeeToken: feeToken,
                expectedCryptoConfigId: p.expectedCryptoConfigId,
                maxFee: p.maxFee
            });
    }

    /**
     * @notice Forward the requester refund of a failed E3 to the account that paid the fee
     * @dev Permissionless; reverts unless the E3 failed and the refund manager has a refund
     * @return amount Refunded amount, in `roundFeeToken`
     */
    function claimFeeRefund() external returns (uint256 amount) {
        if (!roundOpened) revert RoundNotOpened();
        IInterfold.E3Stage stage = interfold.getE3Stage(e3Id);
        if (stage != IInterfold.E3Stage.Failed) revert E3NotFailed(stage);

        amount = IE3RefundManager(interfold.e3RefundManager()).claimRequesterRefund(e3Id);
        roundFeeToken.safeTransfer(feePayer, amount);
        emit CrispFeeRefunded(e3Id, feePayer, amount);
    }

    /// @notice Proposal id behind each CRISP option index (empty until the round opens)
    /// @return Proposal ids in option order
    function optionPids() external view returns (uint256[] memory) {
        return _optionPids;
    }

    // ============================================
    // CENSUS (ERC-5805 subset read by CRISPProgram)
    // ============================================

    /// @notice ERC-6372 clock: timestamps
    /// @return Current timestamp
    function clock() external view returns (uint48) {
        return uint48(block.timestamp);
    }

    /// @notice ERC-6372 clock mode
    /// @return Clock mode descriptor
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() external pure returns (string memory) {
        return "mode=timestamp";
    }

    /**
     * @notice Voting power of `account` at the census snapshot
     * @dev Only the snapshot is recorded. Voting power is frozen once the round opens (signups are
     *      blocked and `castVote` is disabled), so the live value is the snapshot value.
     * @param account Voter
     * @param timepoint Must equal `censusSnapshot`
     * @return Voting power, 18 decimals
     */
    function getPastVotes(address account, uint256 timepoint) external view returns (uint256) {
        if (!roundOpened || timepoint != censusSnapshot) revert UnknownTimepoint(timepoint);
        return _getVotingPower(account);
    }

    /**
     * @notice Total voting power at the census snapshot
     * @param timepoint Must equal `censusSnapshot`
     * @return Total voting power, 18 decimals
     */
    function getPastTotalSupply(uint256 timepoint) external view returns (uint256) {
        if (!roundOpened || timepoint != censusSnapshot) revert UnknownTimepoint(timepoint);
        return censusTotalPower;
    }

    /// @notice Whether `user` can still sign up (RegenStaker integration)
    /// @return True until the round opens
    function canSignup(address) external view returns (bool) {
        return !roundOpened;
    }

    // ============================================
    // HOOKS
    // ============================================

    /// @dev Records the voter for the census; blocked once the round opens
    function _beforeSignupHook(address user) internal override returns (bool) {
        if (roundOpened) return false;
        if (!_isVoter[user]) {
            _isVoter[user] = true;
            _voters.push(user);
        }
        _lastSignupAt = block.timestamp;
        return true;
    }

    /// @dev Keeper or management only, until the round opens
    function _beforeProposeHook(address proposer) internal view override returns (bool) {
        if (proposer == address(0)) revert ZeroAddressCannotPropose();
        if (roundOpened) return false;
        TokenizedAllocationMechanism tam = _tokenizedAllocation();
        return proposer == tam.keeper() || proposer == tam.management();
    }

    /// @dev Deposit normalized to 18 decimals
    function _getVotingPowerHook(address, uint256 deposit) internal view override returns (uint256) {
        uint8 assetDecimals = IERC20Metadata(address(asset)).decimals();
        if (assetDecimals == 18) return deposit;
        if (assetDecimals < 18) return deposit * 10 ** (18 - assetDecimals);
        return deposit / 10 ** (assetDecimals - 18);
    }

    function _validateProposalHook(uint256 pid) internal view override returns (bool) {
        return _proposalExists(pid);
    }

    /// @dev Public votes would reveal voter, project and weight; ballots go to CRISPProgram
    function _processVoteHook(
        uint256,
        address,
        TokenizedAllocationMechanism.VoteType,
        uint256,
        uint256
    ) internal pure override returns (uint256) {
        revert EncryptedBallotsOnly();
    }

    function _hasQuorumHook(uint256 pid) internal view override returns (bool) {
        return _convertVotesToShares(pid) >= _getQuorumShares();
    }

    /// @dev Credits back in voting power units (18 decimals)
    function _convertVotesToShares(uint256 pid) internal view override returns (uint256) {
        return creditsOf[pid] * votingPowerDivisor;
    }

    /**
     * @dev Applies the decrypted tally once the E3 is Complete. A failed E3, or a round that was
     *      never opened, finalizes with no tally so the pool can be swept after the grace period.
     *      Any other stage blocks finalization.
     */
    function _beforeFinalizeVoteTallyHook() internal override returns (bool) {
        if (!roundOpened) return true;

        IInterfold.E3Stage stage = interfold.getE3Stage(e3Id);
        if (stage == IInterfold.E3Stage.Failed) {
            emit CrispRoundFailed(e3Id);
            return true;
        }
        if (stage != IInterfold.E3Stage.Complete) return false;

        uint256[] memory tally = ICRISPProgram(crispProgram).decodeTally(e3Id);
        uint256 numOptions = _optionPids.length;
        for (uint256 i; i < numOptions; ++i) {
            creditsOf[_optionPids[i]] = tally[i];
        }
        emit CrispTallyApplied(e3Id, _optionPids, tally);
        return true;
    }

    function _getRecipientAddressHook(uint256 pid) internal view override returns (address) {
        address recipient = _getProposal(pid).recipient;
        if (recipient == address(0)) revert TokenizedAllocationMechanism.InvalidRecipient(recipient);
        return recipient;
    }

    function _requestCustomDistributionHook(address, uint256) internal pure override returns (bool, uint256) {
        return (false, 0);
    }

    /// @dev Matching pool plus signup deposits
    function _calculateTotalAssetsHook() internal view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @notice Reject ETH
    receive() external payable override {
        revert("ETH not supported - use ERC20 tokens only");
    }
}
