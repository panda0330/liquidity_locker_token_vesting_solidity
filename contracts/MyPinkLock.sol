// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "./IPinkLockNew.sol";
import "./IUniswapV2Router02.sol";
import "./IUniswapV2Pair.sol";
import "./IUniswapV2Factory.sol";
import "./FullMath.sol";
import "./Ownable.sol";

contract MyPinkLock02 is IPinkLockNew, Pausable, Ownable {
    using Address for address payable;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;
    using SafeERC20 for IERC20;

    struct Lock {
        uint256 id;
        address token;
        address owner;
        uint256 amount;
        uint256 lockDate;
        uint256 unlockDate;
        uint256 withdrawnAmount;
        string description;
        bool isVesting;
    }

    struct CumulativeLockInfo {
        address token;
        address factory;
        uint256 amount;
    }

    struct FeeStruct {
        uint256 ethFee; // Small eth fee to prevent spam on the platform
        uint256 ethEditFee; // Small eth fee
        address referralToken; // token the refferer must hold to qualify as a referrer
        uint256 referralHold; // balance the referrer must hold to qualify as a referrer
        uint256 referralDiscountEthFee; // discount on flatrate fees for using a valid referral address
    }

    // ID padding from PinkLock v1, as there is a lack of a pausing mechanism
    // as of now the lastest id from v1 is about 22K, so this is probably a safe padding value.
    uint256 private constant ID_PADDING = 1_000_000;

    Lock[] private _locks;

    FeeStruct public gFees;

    mapping(address => EnumerableSet.UintSet) private _userLpLockIds;
    mapping(address => EnumerableSet.UintSet) private _userNormalLockIds;

    EnumerableSet.AddressSet private _lpLockedTokens;
    EnumerableSet.AddressSet private _normalLockedTokens;
    mapping(address => CumulativeLockInfo) public cumulativeLockInfo;
    mapping(address => EnumerableSet.UintSet) private _tokenToLockIds;

    event LockAdded(
        uint256 indexed id,
        address token,
        address owner,
        uint256 amount,
        uint256 unlockDate
    );
    event LockUpdated(
        uint256 indexed id,
        address token,
        address owner,
        uint256 newAmount,
        uint256 newUnlockDate
    );

}
