// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import './IFrankencoin.sol';
import './IPositionV1.sol';

interface IMintingHubV1 {
	struct Challenge {
		address challenger;
		uint64 start;
		IPositionV1 position;
		uint256 size;
	}

	// Constants
	function OPENING_FEE() external pure returns (uint256);

	function CHALLENGER_REWARD() external pure returns (uint32);

	// View functions
	function zchf() external view returns (IFrankencoin);

	function challenges(uint256 index) external view returns (address, uint64, IPositionV1, uint256);

	function pendingReturns(address collateral, address owner) external view returns (uint256);

	function price(uint32 challengeNumber) external view returns (uint256);

	// State modifying functions
	function openPosition(
		address _collateralAddress,
		uint256 _minCollateral,
		uint256 _initialCollateral,
		uint256 _mintingMaximum,
		uint256 _initPeriodSeconds,
		uint256 _expirationSeconds,
		uint64 _challengeSeconds,
		uint32 _annualInterestPPM,
		uint256 _liqPrice,
		uint32 _reservePPM
	) external returns (address);

	function openPositionOneWeek(
		address _collateralAddress,
		uint256 _minCollateral,
		uint256 _initialCollateral,
		uint256 _mintingMaximum,
		uint256 _expirationSeconds,
		uint64 _challengeSeconds,
		uint32 _annualInterestPPM,
		uint256 _liqPrice,
		uint32 _reservePPM
	) external returns (address);

	function clone(
		address position,
		uint256 _initialCollateral,
		uint256 _initialMint,
		uint256 expiration
	) external returns (address);

	function challenge(
		address _positionAddr,
		uint256 _collateralAmount,
		uint256 expectedPrice
	) external returns (uint256);

	function bid(uint32 _challengeNumber, uint256 size, bool postponeCollateralReturn) external;

	function returnPostponedCollateral(address collateral, address target) external;

	// Events
	event PositionOpened(
		address indexed owner,
		address indexed position,
		address zchf,
		address collateral,
		uint256 price
	);
	event ChallengeStarted(address indexed challenger, address indexed position, uint256 size, uint256 number);
	event ChallengeAverted(address indexed position, uint256 number, uint256 size);
	event ChallengeSucceeded(
		address indexed position,
		uint256 number,
		uint256 bid,
		uint256 acquiredCollateral,
		uint256 challengeSize
	);
	event PostPonedReturn(address collateral, address indexed beneficiary, uint256 amount);
}
