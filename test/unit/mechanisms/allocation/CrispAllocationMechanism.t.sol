// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { TokenizedAllocationMechanism } from "src/mechanisms/TokenizedAllocationMechanism.sol";
import { AllocationConfig } from "src/mechanisms/BaseAllocationMechanism.sol";
import { CrispAllocationMechanism } from "src/mechanisms/mechanism/CrispAllocationMechanism.sol";
import { IInterfold } from "src/interfaces/IInterfoldCrisp.sol";

interface ICensus {
    function clock() external view returns (uint48);
    function getPastVotes(address account, uint256 timepoint) external view returns (uint256);
    function getPastTotalSupply(uint256 timepoint) external view returns (uint256);
}

/// @dev Interfold stand-in. `request` performs the same census probes CRISPProgram._initCredits
///      and _tokenSnapshot make inside the request transaction, and pulls the fee like Interfold.
contract InterfoldStandIn {
    IERC20 public feeToken;
    address public e3RefundManager;
    uint256 public quote;
    uint256 public lastE3Id;
    bytes public lastCustomParams;
    uint256[2] public lastInputWindow;
    address public lastProgram;
    uint256 public probedTotalSupply;
    mapping(uint256 => IInterfold.E3Stage) public stages;

    constructor(IERC20 _feeToken, address _refundManager, uint256 _quote) {
        feeToken = _feeToken;
        e3RefundManager = _refundManager;
        quote = _quote;
    }

    function getE3Quote(IInterfold.E3RequestParams calldata) external view returns (uint256) {
        return quote;
    }

    function request(IInterfold.E3RequestParams calldata p) external returns (uint256 e3Id) {
        require(p.maxFee >= quote, "maxFee");
        require(address(p.expectedFeeToken) == address(feeToken), "feeToken");
        (address votesToken, , , , , , ) = abi.decode(
            p.customParams,
            (address, uint256, uint256, uint256, uint256, uint256, uint256)
        );
        uint256 snapshot = ICensus(votesToken).clock() - 1;
        probedTotalSupply = ICensus(votesToken).getPastTotalSupply(snapshot);
        ICensus(votesToken).getPastVotes(address(0), snapshot);

        feeToken.transferFrom(msg.sender, address(this), quote);
        e3Id = ++lastE3Id;
        lastCustomParams = p.customParams;
        lastInputWindow = p.inputWindow;
        lastProgram = p.e3Program;
        stages[e3Id] = IInterfold.E3Stage.Requested;
    }

    function getE3Stage(uint256 e3Id) external view returns (IInterfold.E3Stage) {
        return stages[e3Id];
    }

    function setStage(uint256 e3Id, IInterfold.E3Stage stage) external {
        stages[e3Id] = stage;
    }
}

contract CrispProgramStandIn {
    mapping(uint256 => uint256[]) internal _tallies;

    function setTally(uint256 e3Id, uint256[] calldata tally) external {
        _tallies[e3Id] = tally;
    }

    function decodeTally(uint256 e3Id) external view returns (uint256[] memory) {
        return _tallies[e3Id];
    }
}

contract RefundManagerStandIn {
    ERC20Mock internal immutable token;
    uint256 public refund;

    constructor(ERC20Mock _token, uint256 _refund) {
        token = _token;
        refund = _refund;
    }

    function claimRequesterRefund(uint256) external returns (uint256) {
        token.mint(msg.sender, refund);
        return refund;
    }
}

contract CrispAllocationMechanismTest is Test {
    uint256 internal constant VOTING_DELAY = 1 hours;
    uint256 internal constant VOTING_PERIOD = 1 days;
    uint256 internal constant TIMELOCK = 1 days;
    uint256 internal constant GRACE = 7 days;
    uint256 internal constant DIVISOR = 1e18; // one ballot credit per whole token of voting power
    uint256 internal constant FEE = 5e6;
    uint256 internal constant REFUND = 4e6;
    uint256 internal constant MATCHING_POOL = 1000e18;

    ERC20Mock internal asset;
    ERC20Mock internal feeToken;
    InterfoldStandIn internal interfold;
    CrispProgramStandIn internal program;
    RefundManagerStandIn internal refundManager;
    CrispAllocationMechanism internal mechanism;
    TokenizedAllocationMechanism internal tam;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal recipient1 = makeAddr("recipient1");
    address internal recipient2 = makeAddr("recipient2");
    address internal recipient3 = makeAddr("recipient3");

    function setUp() public {
        asset = new ERC20Mock();
        feeToken = new ERC20Mock();
        program = new CrispProgramStandIn();
        refundManager = new RefundManagerStandIn(feeToken, REFUND);
        interfold = new InterfoldStandIn(IERC20(address(feeToken)), address(refundManager), FEE);

        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(asset)),
            name: "CRISP Allocation",
            symbol: "CRISP",
            votingDelay: VOTING_DELAY,
            votingPeriod: VOTING_PERIOD,
            quorumShares: 1e18,
            timelockDelay: TIMELOCK,
            gracePeriod: GRACE,
            owner: owner
        });
        mechanism = new CrispAllocationMechanism(
            address(new TokenizedAllocationMechanism()),
            config,
            IInterfold(address(interfold)),
            address(program)
        );
        tam = TokenizedAllocationMechanism(address(mechanism));

        _signup(alice, 10e18);
        _signup(bob, 20e18);
        _signup(carol, 30e18);
        asset.mint(address(mechanism), MATCHING_POOL);

        vm.startPrank(owner);
        tam.propose(recipient1, "Project 1");
        tam.propose(recipient2, "Project 2");
        tam.propose(recipient3, "Project 3");
        vm.stopPrank();

        feeToken.mint(owner, FEE);
        vm.prank(owner);
        feeToken.approve(address(mechanism), FEE);
    }

    function _signup(address user, uint256 amount) internal {
        asset.mint(user, amount);
        vm.startPrank(user);
        asset.approve(address(mechanism), amount);
        tam.signup(amount);
        vm.stopPrank();
    }

    function _roundParams() internal pure returns (CrispAllocationMechanism.RoundParams memory) {
        return
            CrispAllocationMechanism.RoundParams({
                committeeSize: IInterfold.CommitteeSize.Minimum,
                paramSet: 0,
                expectedCryptoConfigId: bytes32(0),
                computeProviderParams: "",
                votingPowerDivisor: DIVISOR,
                maxFee: FEE
            });
    }

    function _openRound() internal returns (uint256 e3Id) {
        vm.warp(block.timestamp + 1);
        vm.prank(owner);
        e3Id = mechanism.openRound(_roundParams());
    }

    function _completeWith(uint256 e3Id, uint256[3] memory credits) internal {
        uint256[] memory tally = new uint256[](3);
        for (uint256 i; i < 3; ++i) tally[i] = credits[i];
        program.setTally(e3Id, tally);
        interfold.setStage(e3Id, IInterfold.E3Stage.Complete);
    }

    function test_openRound_requestsOnchainCensusRoundOverVotingWindow() public {
        uint256 e3Id = _openRound();

        (
            address votesToken,
            uint256 minVotingPower,
            uint256 numOptions,
            uint256 creditMode,
            uint256 credits,
            uint256 censusMode,
            uint256 divisor
        ) = abi.decode(interfold.lastCustomParams(), (address, uint256, uint256, uint256, uint256, uint256, uint256));
        assertEq(votesToken, address(mechanism));
        assertEq(minVotingPower, DIVISOR);
        assertEq(numOptions, 3);
        assertEq(creditMode, 1, "CUSTOM");
        assertEq(credits, 0);
        assertEq(censusMode, 2, "ONCHAIN");
        assertEq(divisor, DIVISOR);
        assertEq(interfold.lastInputWindow(0), tam.votingStartTime());
        assertEq(interfold.lastInputWindow(1), tam.votingEndTime());
        assertEq(interfold.lastProgram(), address(program));

        assertEq(mechanism.e3Id(), e3Id);
        assertEq(interfold.probedTotalSupply(), 60e18);
        assertEq(feeToken.balanceOf(address(interfold)), FEE);
        assertEq(feeToken.balanceOf(owner), 0);

        uint256 snapshot = mechanism.censusSnapshot();
        assertEq(snapshot, block.timestamp - 1);
        assertEq(mechanism.getPastVotes(bob, snapshot), 20e18);
        uint256[] memory pids = mechanism.optionPids();
        assertEq(pids.length, 3);
        assertEq(pids[2], 3);
    }

    function test_openRound_skipsCanceledProposalsInOptionOrder() public {
        vm.prank(owner);
        tam.cancelProposal(2);

        _openRound();

        uint256[] memory pids = mechanism.optionPids();
        assertEq(pids.length, 2);
        assertEq(pids[0], 1);
        assertEq(pids[1], 3);
    }

    function test_openRound_revertsInBlockWithSignup() public {
        _signup(alice, 1e18);
        vm.prank(owner);
        vm.expectRevert(CrispAllocationMechanism.SignupInCurrentBlock.selector);
        mechanism.openRound(_roundParams());
    }

    function test_openRound_revertsAfterVotingStarts() public {
        uint256 votingStart = tam.votingStartTime();
        vm.warp(votingStart + 1);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(CrispAllocationMechanism.VotingAlreadyStarted.selector, votingStart + 1, votingStart)
        );
        mechanism.openRound(_roundParams());
    }

    function test_openRound_revertsWhenFeeQuoteExceedsMax() public {
        CrispAllocationMechanism.RoundParams memory p = _roundParams();
        p.maxFee = FEE - 1;
        vm.warp(block.timestamp + 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CrispAllocationMechanism.FeeAboveMax.selector, FEE, FEE - 1));
        mechanism.openRound(p);
    }

    function test_openRound_freezesSignupsAndProposals() public {
        _openRound();

        asset.mint(alice, 1e18);
        vm.startPrank(alice);
        asset.approve(address(mechanism), 1e18);
        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.RegistrationBlocked.selector, alice));
        tam.signup(1e18);
        vm.stopPrank();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.ProposeNotAllowed.selector, owner));
        tam.propose(makeAddr("late"), "Late project");

        assertFalse(mechanism.canSignup(alice));
    }

    function test_castVote_isDisabled() public {
        _openRound();
        vm.warp(tam.votingStartTime() + 1);

        vm.prank(alice);
        vm.expectRevert(CrispAllocationMechanism.EncryptedBallotsOnly.selector);
        tam.castVote(1, TokenizedAllocationMechanism.VoteType.For, 1e18, recipient1);
    }

    function test_getPastVotes_rejectsTimepointsOtherThanSnapshot() public {
        vm.expectRevert(abi.encodeWithSelector(CrispAllocationMechanism.UnknownTimepoint.selector, 0));
        mechanism.getPastVotes(alice, 0);

        _openRound();
        uint256 other = mechanism.censusSnapshot() - 1;
        vm.expectRevert(abi.encodeWithSelector(CrispAllocationMechanism.UnknownTimepoint.selector, other));
        mechanism.getPastTotalSupply(other);
    }

    function test_finalize_blockedUntilE3Complete() public {
        uint256 e3Id = _openRound();
        interfold.setStage(e3Id, IInterfold.E3Stage.CiphertextReady);
        vm.warp(tam.votingEndTime() + 1);

        vm.prank(owner);
        vm.expectRevert(TokenizedAllocationMechanism.FinalizationBlocked.selector);
        tam.finalizeVoteTally();
    }

    function test_completedRound_distributesPoolProRataToCredits() public {
        uint256 e3Id = _openRound();
        vm.warp(tam.votingEndTime() + 1);
        _completeWith(e3Id, [uint256(40), 20, 0]);

        vm.prank(owner);
        tam.finalizeVoteTally();

        assertEq(mechanism.creditsOf(1), 40);
        assertEq(mechanism.creditsOf(2), 20);
        tam.queueProposal(1);
        tam.queueProposal(2);
        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.NoQuorum.selector, 3, 0, 0, 1e18));
        tam.queueProposal(3);

        vm.warp(tam.globalRedemptionStart());
        uint256 pool = MATCHING_POOL + 60e18;
        uint256 shares1 = tam.balanceOf(recipient1);
        uint256 shares2 = tam.balanceOf(recipient2);
        vm.prank(recipient1);
        tam.redeem(shares1, recipient1, recipient1);
        vm.prank(recipient2);
        tam.redeem(shares2, recipient2, recipient2);

        assertEq(asset.balanceOf(recipient1), (pool * 2) / 3);
        assertApproxEqAbs(asset.balanceOf(recipient2), pool / 3, 1);
    }

    function test_failedRound_finalizesEmptyRefundsFeeAndAllowsSweep() public {
        uint256 e3Id = _openRound();
        interfold.setStage(e3Id, IInterfold.E3Stage.Failed);
        vm.warp(tam.votingEndTime() + 1);

        vm.prank(owner);
        tam.finalizeVoteTally();
        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.NoQuorum.selector, 1, 0, 0, 1e18));
        tam.queueProposal(1);

        mechanism.claimFeeRefund();
        assertEq(feeToken.balanceOf(owner), REFUND);

        vm.warp(tam.globalRedemptionStart() + GRACE + 1);
        address treasury = makeAddr("treasury");
        vm.prank(owner);
        tam.sweep(address(asset), treasury);
        assertEq(asset.balanceOf(treasury), MATCHING_POOL + 60e18);
    }

    function test_claimFeeRefund_revertsUnlessFailed() public {
        uint256 e3Id = _openRound();
        interfold.setStage(e3Id, IInterfold.E3Stage.KeyPublished);

        vm.expectRevert(
            abi.encodeWithSelector(CrispAllocationMechanism.E3NotFailed.selector, IInterfold.E3Stage.KeyPublished)
        );
        mechanism.claimFeeRefund();
    }
}
