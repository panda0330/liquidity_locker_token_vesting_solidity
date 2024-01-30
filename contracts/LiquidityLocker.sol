// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "./Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LiquidityLocker is Ownable, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;

    struct UserInfo {
        EnumerableSet.AddressSet lockedTokens; // records all tokens the user has locked
        mapping(address => uint256[]) locksForToken; // map erc20 address to lock id for that token
    }

    struct TokenLock {
        uint256 lockDate; // the date the token was locked
        uint256 amount; // the amount of tokens still locked (initialAmount minus withdrawls)
        uint256 initialAmount; // the initial lock amount
        uint256 unlockDate; // the date the token can be withdrawn
        uint256 lockID; // lockID nonce per lp token
        address owner;
    }

    mapping(address => UserInfo) private users;

    EnumerableSet.AddressSet private lockedTokens;

    mapping(address => TokenLock[]) public tokenLocks; //map lp token to all its locks

    struct FeeStruct {
        uint256 ethFee; // Small eth fee to prevent spam on the platform
        uint256 ethEditFee; // Small eth fee
        IERC20 referralToken; // token the refferer must hold to qualify as a referrer
        uint256 referralHold; // balance the referrer must hold to qualify as a referrer
        uint256 referralDiscountEthFee; // discount on flatrate fees for using a valid referral address
    }

    FeeStruct public gFees;

    event onDeposit(
        address lpToken,
        address user,
        uint256 amount,
        uint256 lockDate,
        uint256 unlockDate
    );
    event onWithdraw(address lpToken, uint256 amount);

    constructor() {
        gFees.ethFee = 8e16; // 0.08 eth
        gFees.ethEditFee = 5e16; // 0.05 eth
        gFees.referralToken = IERC20(
            0xC98f38D074Cb3cf8da4AC30EB99632233465aE20
        );
        gFees.referralHold = 100e18; // 100 token
        gFees.referralDiscountEthFee = 6e16; // 0.06 eth
    }

    function setFees(
        uint256 ethFee,
        uint256 ethEditFee,
        uint256 referralDiscountEthFee
    ) public onlyOwner {
        gFees.ethFee = ethFee;
        gFees.ethEditFee = ethEditFee;
        gFees.referralDiscountEthFee = referralDiscountEthFee;
    }

    
}
