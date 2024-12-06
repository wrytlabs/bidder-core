// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {ERC721} from '@openzeppelin/contracts/token/ERC721/ERC721.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {ISwapRouter} from '@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol';
import {IQuoter} from '@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol';

import {IFrankencoin} from './Frankencoin/IFrankencoin.sol';
import {IMintingHubV1} from './Frankencoin/IMintingHubV1.sol';
import {IPositionV1} from './Frankencoin/IPositionV1.sol';

contract BidderManagerV1 is ERC721 {
	using Math for uint256;

	ISwapRouter public immutable swapRouter;
	IQuoter public immutable quoter;

	IFrankencoin public immutable zchf;
	IMintingHubV1 public immutable hub;

	uint256 public immutable fee = 100_000; // executor fee, everyone can execute, 10% of profits

	uint256 public tokenCnt;
	uint256 public totalFunds;
	uint256 public totalRewards;
	uint256 public refRatio = 1 ether;

	struct Fund {
		uint256 amount;
		uint256 refRatio;
	}

	mapping(uint256 tokenId => Fund) public funds;

	// ---------------------------------------------------------------------------------------

	event Create(address indexed owner, uint256 tokenId, uint256 amount, uint256 refRatio);
	event Close(address indexed owner, uint256 tokenId, uint256 funds, uint256 payout);
	event Execute(
		address indexed executor,
		uint256 challengeIndex,
		address collateral,
		uint256 size,
		uint256 bidded,
		uint256 swapped,
		uint256 profit
	);

	// ---------------------------------------------------------------------------------------

	error NoChange();
	error NoFunds();
	error NoLoss(uint256 zchfBefore, uint256 zchfAfter);
	error WrongInputToken(address input, address needed);
	error WrongOutputToken(address output, address needed);

	// ---------------------------------------------------------------------------------------

	constructor(
		ISwapRouter _swapRouter,
		IQuoter _quoter,
		IFrankencoin _zchf,
		IMintingHubV1 _hub,
		string memory name,
		string memory symbol
	) ERC721(name, symbol) {
		swapRouter = _swapRouter;
		quoter = _quoter;
		zchf = _zchf;
		hub = _hub;
	}

	// ---------------------------------------------------------------------------------------

	function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721) returns (bool) {
		return super.supportsInterface(interfaceId);
	}

	// ---------------------------------------------------------------------------------------

	function create(uint256 amount) public returns (uint256) {
		return createTo(msg.sender, amount);
	}

	function createTo(address to, uint256 amount) public returns (uint256) {
		if (to == address(0) || amount == 0) revert NoChange();
		tokenCnt += 1;

		zchf.transferFrom(to, address(this), amount);
		totalFunds += amount;
		funds[tokenCnt].amount = amount;
		funds[tokenCnt].refRatio = refRatio;

		_mint(to, tokenCnt);

		emit Create(to, tokenCnt, amount, refRatio);
		return tokenCnt;
	}

	// ---------------------------------------------------------------------------------------

	function close(uint256 tokenId) public {
		// check ownership
		address owner = ownerOf(tokenId);
		if (owner != msg.sender) revert ERC721IncorrectOwner(msg.sender, tokenId, owner);

		Fund memory user = funds[tokenId];
		uint256 diff = refRatio - user.refRatio;
		uint256 payout = user.amount * (1 + diff / 1 ether);

		// clean up
		totalFunds -= user.amount;
		_burn(tokenId);
		delete funds[tokenId];

		// pay out
		zchf.transfer(msg.sender, payout);

		emit Close(msg.sender, tokenId, user.amount, payout);
	}

	// ---------------------------------------------------------------------------------------

	function quoteAuction(
		uint256 index
	) public view returns (address collateralToken, uint256 collateralAmount, uint256 zchfNeeded) {
		// Get challenge info
		(, , IPositionV1 position, uint256 size) = hub.challenges(index);
		address collateral = address(position.collateral());
		if (size == 0) return (collateral, 0, 0);

		// Get auction price
		uint256 price = hub.price(uint32(index));
		if (price == 0) return (collateral, 0, 0);

		// Calculate max possible based on ZCHF balance
		uint256 balance = zchf.balanceOf(address(this));
		uint256 maxCollateral = (balance * 1 ether) / price;

		// Return actual amounts
		uint256 actualCollateral = Math.min(size, maxCollateral);
		uint256 actualZCHF = (actualCollateral * price) / 1 ether;

		return (collateral, actualCollateral, actualZCHF);
	}

	// ---------------------------------------------------------------------------------------

	function encodePath(address[] memory tokens, uint24[] memory fees) public pure returns (bytes memory) {
		require(tokens.length >= 2 && tokens.length - 1 == fees.length);

		bytes memory path = new bytes(0);
		for (uint256 i = 0; i < fees.length; i++) {
			path = abi.encodePacked(path, tokens[i], fees[i]);
		}
		path = abi.encodePacked(path, tokens[tokens.length - 1]);

		return path;
	}

	function quoteUniswap(address[] memory tokens, uint24[] memory fees, uint256 amountIn) public returns (uint256) {
		bytes memory path = encodePath(tokens, fees);
		try quoter.quoteExactInput(path, amountIn) returns (uint256 amount) {
			return amount;
		} catch {
			return 0;
		}
	}

	// ---------------------------------------------------------------------------------------

	function execute(uint256 index, address[] memory tokens, uint24[] memory fees) public {
		(address coll, uint256 size, uint256 toBid) = quoteAuction(index);

		// check token path entry and outcome
		if (tokens[0] != address(coll)) revert WrongInputToken(tokens[0], address(coll));
		if (tokens[tokens.length - 1] != address(zchf))
			revert WrongOutputToken(tokens[tokens.length - 1], address(zchf));

		// check zchf balance before
		uint256 zchfBefore = zchf.balanceOf(address(this));
		if (zchfBefore == 0) revert NoFunds();

		// take bid
		hub.bid(uint32(index), size, false);

		// swap
		uint256 swapped = executeSwap(tokens, fees, size, toBid);

		// play fair
		zchf.transfer(msg.sender, (swapped * fee) / 1_000_000); // @dev: pay out executor fee PPM

		// check zchf balance afterwards
		uint256 zchfAfter = zchf.balanceOf(address(this));
		if (zchfAfter < zchfBefore) revert NoLoss(zchfBefore, zchfAfter);

		// profit, overflow checked before
		uint256 profit = zchfAfter - zchfBefore;
		refRatio += (profit * 1 ether) / totalFunds;
		totalRewards += profit;

		// emit
		emit Execute(msg.sender, index, coll, size, toBid, swapped, profit);
	}

	function executeSwap(
		address[] memory tokens,
		uint24[] memory fees,
		uint256 amountIn,
		uint256 amountOutMinimum
	) internal returns (uint256) {
		// approve to router
		IERC20(tokens[0]).approve(address(swapRouter), IERC20(tokens[0]).balanceOf(address(this)));

		// setup swap
		ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams({
			path: encodePath(tokens, fees),
			recipient: address(this),
			deadline: block.timestamp,
			amountIn: amountIn,
			amountOutMinimum: amountOutMinimum // @dev: first check, to ensure to cover bid amount
		});

		// execute and return
		return swapRouter.exactInput(params);
	}

	// ---------------------------------------------------------------------------------------
}
