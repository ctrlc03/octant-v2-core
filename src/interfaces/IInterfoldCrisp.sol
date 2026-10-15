// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Interfold / CRISP interface subset
 * @notice The calls CrispAllocationMechanism makes into Interfold and CRISPProgram.
 * @dev Copied from the npm packages interfold/contracts 0.19.0 (`IInterfold.sol`, `IE3RefundManager.sol`)
 *      and crisp-e3/contracts 0.26.0 (`CRISPProgram.sol`). The upstream files pin
 *      `pragma solidity 0.8.28`, which this repository's pinned compiler cannot build, so they cannot
 *      be imported directly. The struct and enum layouts must stay identical to upstream: a mismatch
 *      makes `request` revert with empty data.
 */
interface IInterfold {
    /// @notice Committee sizes, in upstream declaration order
    enum CommitteeSize {
        Minimum,
        Micro,
        Small
    }

    /// @notice E3 lifecycle stages, in upstream declaration order
    enum E3Stage {
        None,
        Requested,
        CommitteeFinalized,
        KeyPublished,
        CiphertextReady,
        Complete,
        Failed
    }

    /// @notice Parameters of an E3 request
    /// @param committeeSize Committee size tier
    /// @param inputWindow [start, end] timestamps during which the program accepts inputs
    /// @param e3Program E3 program contract (CRISPProgram)
    /// @param paramSet BFV parameter set index
    /// @param computeProviderParams Opaque compute provider parameters
    /// @param customParams Program-specific parameters
    /// @param expectedFeeToken Fee token the requester accepts
    /// @param expectedCryptoConfigId Circuit configuration the requester accepts
    /// @param maxFee Maximum fee the requester accepts
    struct E3RequestParams {
        CommitteeSize committeeSize;
        uint256[2] inputWindow;
        address e3Program;
        uint8 paramSet;
        bytes computeProviderParams;
        bytes customParams;
        IERC20 expectedFeeToken;
        bytes32 expectedCryptoConfigId;
        uint256 maxFee;
    }

    /// @notice Request an E3; pulls the fee from msg.sender
    /// @dev Upstream also returns the E3 struct; ABI decoding ignores the trailing data
    /// @param requestParams Request parameters
    /// @return e3Id Identifier of the new E3
    function request(E3RequestParams calldata requestParams) external returns (uint256 e3Id);

    /// @notice Fee quote for a request
    /// @param e3Params Request parameters
    /// @return fee Fee in fee token units
    function getE3Quote(E3RequestParams calldata e3Params) external view returns (uint256 fee);

    /// @notice Current fee token
    /// @return Fee token
    function feeToken() external view returns (IERC20);

    /// @notice Current lifecycle stage of an E3
    /// @param e3Id E3 identifier
    /// @return stage Lifecycle stage
    function getE3Stage(uint256 e3Id) external view returns (E3Stage stage);

    /// @notice Refund manager for failed E3s
    /// @return Refund manager address
    function e3RefundManager() external view returns (address);
}

/// @notice Refund manager subset
interface IE3RefundManager {
    /// @notice Claim the requester share of a failed E3's fee; pays msg.sender, which must be the requester
    /// @param e3Id E3 identifier
    /// @return amount Amount paid, in the E3's fee token
    function claimRequesterRefund(uint256 e3Id) external returns (uint256 amount);
}

/// @notice CRISPProgram subset
interface ICRISPProgram {
    /// @notice Per-option total ballot weight of a completed round
    /// @param e3Id E3 identifier
    /// @return votes Total weight per option, in ballot credits
    function decodeTally(uint256 e3Id) external view returns (uint256[] memory votes);

    /// @notice Divisor that converts raw voting power to ballot credits for a round
    /// @param e3Id E3 identifier
    /// @return Divisor
    function votingPowerDivisorOf(uint256 e3Id) external view returns (uint256);
}

/// @notice CRISPProgram credit modes, in upstream declaration order
enum CrispCreditMode {
    CONSTANT,
    CUSTOM
}

/// @notice CRISPProgram census modes, in upstream declaration order
enum CrispCensusMode {
    TOKEN,
    BY_REQUESTER,
    ONCHAIN
}
