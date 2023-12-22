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
    event LockRemoved(
        uint256 indexed id,
        address token,
        address owner,
        uint256 amount,
        uint256 unlockedAt
    );
    event LockVested(
        uint256 indexed id,
        address token,
        address owner,
        uint256 amount,
        uint256 total,
        uint256 timestamp
    );
    event LockDescriptionChanged(uint256 lockId);
    event LockOwnerChanged(uint256 lockId, address owner, address newOwner);

    modifier validLock(uint256 lockId) {
        _getActualIndex(lockId);
        _;
    }

    constructor() {
        gFees.ethFee = 8e12; // 0.08 eth
        gFees.ethEditFee = 5e12; // 0.05 eth
        gFees.referralToken = address(
            0xAe6D3803B3358b09894e2f53A9f7B6A80d648B4C
        );
        gFees.referralHold = 100e18; // 100 token
        gFees.referralDiscountEthFee = 6e12; // 0.06 eth
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

    function setReferralTokenAndHold(
        address referralToken,
        uint256 referralHold
    ) public onlyOwner {
        gFees.referralToken = address(referralToken);
        gFees.referralHold = referralHold;
    }

    function lock(
        address owner,
        address token,
        bool isLpToken,
        uint256 amount,
        uint256 unlockDate,
        string memory description
    ) external payable override returns (uint256 id) {
        require(
            unlockDate > block.timestamp,
            "Unlock date should be in the future"
        );

        require(unlockDate < 1e10, "Timestamp invalid"); // prevents errors when timestamp entered in milliseconds

        require(amount > 0, "Amount should be greater than 0");

        uint256 validFee;
        if (!hasRefferalTokenHold(msg.sender)) {
            validFee = gFees.ethFee;
        } else {
            validFee = gFees.referralDiscountEthFee;
        }

        require(msg.value == validFee, "SERVICE FEE");

        id = _createLock(
            owner,
            token,
            isLpToken,
            amount,
            unlockDate,
            description,
            false
        );
        _safeTransferFromEnsureExactAmount(
            token,
            msg.sender,
            address(this),
            amount
        );
        emit LockAdded(id, token, owner, amount, unlockDate);
        return id;
    }

    function vestingLock(
        address owner,
        address token,
        bool isLpToken,
        uint256 amount,
        uint256 unlockDate,
        string memory description
    ) external payable override returns (uint256 id) {
        require(unlockDate > block.timestamp, "Unlock should be in the future");
        require(unlockDate < 1e10, "Timestamp invalid"); // prevents errors when timestamp entered in milliseconds
        require(amount > 0, "Amount should be greater than 0");

        uint256 validFee;
        if (!hasRefferalTokenHold(msg.sender)) {
            validFee = gFees.ethFee;
        } else {
            validFee = gFees.referralDiscountEthFee;
        }

        require(msg.value == validFee, "SERVICE FEE");

        id = _createLock(
            owner,
            token,
            isLpToken,
            amount,
            unlockDate,
            description,
            true
        );
        _safeTransferFromEnsureExactAmount(
            token,
            msg.sender,
            address(this),
            amount
        );
        emit LockAdded(id, token, owner, amount, unlockDate);
        return id;
    }

    function _sumAmount(
        uint256[] calldata amounts
    ) internal pure returns (uint256) {
        uint256 sum = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            if (amounts[i] == 0) {
                revert("Amount cant be zero");
            }
            sum += amounts[i];
        }
        return sum;
    }

    function _createLock(
        address owner,
        address token,
        bool isLpToken,
        uint256 amount,
        uint256 unlockDate,
        string memory description,
        bool isVesting
    ) internal returns (uint256 id) {
        if (isLpToken) {
            address possibleFactoryAddress = _parseFactoryAddress(token);
            id = _lockLpToken(
                owner,
                token,
                possibleFactoryAddress,
                amount,
                unlockDate,
                description,
                isVesting
            );
        } else {
            id = _lockNormalToken(
                owner,
                token,
                amount,
                unlockDate,
                description,
                isVesting
            );
        }
        return id;
    }

    function _lockLpToken(
        address owner,
        address token,
        address factory,
        uint256 amount,
        uint256 unlockDate,
        string memory description,
        bool isVesting
    ) private returns (uint256 id) {
        id = _registerLock(
            owner,
            token,
            amount,
            unlockDate,
            description,
            isVesting
        );
        _userLpLockIds[owner].add(id);
        _lpLockedTokens.add(token);

        CumulativeLockInfo storage tokenInfo = cumulativeLockInfo[token];
        if (tokenInfo.token == address(0)) {
            tokenInfo.token = token;
            tokenInfo.factory = factory;
        }
        tokenInfo.amount = tokenInfo.amount + amount;

        _tokenToLockIds[token].add(id);
    }

    function _lockNormalToken(
        address owner,
        address token,
        uint256 amount,
        uint256 unlockDate,
        string memory description,
        bool isVesting
    ) private returns (uint256 id) {
        id = _registerLock(
            owner,
            token,
            amount,
            unlockDate,
            description,
            isVesting
        );
        _userNormalLockIds[owner].add(id);
        _normalLockedTokens.add(token);

        CumulativeLockInfo storage tokenInfo = cumulativeLockInfo[token];
        if (tokenInfo.token == address(0)) {
            tokenInfo.token = token;
            tokenInfo.factory = address(0);
        }
        tokenInfo.amount = tokenInfo.amount + amount;

        _tokenToLockIds[token].add(id);
    }

    function _registerLock(
        address owner,
        address token,
        uint256 amount,
        uint256 unlockDate,
        string memory description,
        bool isVesting
    ) private whenNotPaused returns (uint256 id) {
        id = _locks.length + ID_PADDING;
        Lock memory newLock = Lock({
            id: id,
            token: token,
            owner: owner,
            amount: amount,
            lockDate: block.timestamp,
            unlockDate: unlockDate,
            withdrawnAmount: 0,
            description: description,
            isVesting: isVesting
        });
        _locks.push(newLock);
    }

    function unlock(uint256 lockId) external override validLock(lockId) {
        Lock storage userLock = _locks[_getActualIndex(lockId)];
        require(
            userLock.owner == msg.sender,
            "You are not the owner of this lock"
        );

        if (userLock.isVesting) {
            _vestingUnlock(userLock);
        } else {
            _normalUnlock(userLock);
        }
    }

    function _normalUnlock(Lock storage userLock) internal {
        require(
            block.timestamp >= userLock.unlockDate,
            "It is not time to unlock"
        );
        require(userLock.withdrawnAmount == 0, "Nothing to unlock");

        CumulativeLockInfo storage tokenInfo = cumulativeLockInfo[
            userLock.token
        ];

        bool isLpToken = tokenInfo.factory != address(0);

        if (isLpToken) {
            _userLpLockIds[msg.sender].remove(userLock.id);
        } else {
            _userNormalLockIds[msg.sender].remove(userLock.id);
        }

        uint256 unlockAmount = userLock.amount;

        if (tokenInfo.amount <= unlockAmount) {
            tokenInfo.amount = 0;
        } else {
            tokenInfo.amount = tokenInfo.amount - unlockAmount;
        }

        if (tokenInfo.amount == 0) {
            if (isLpToken) {
                _lpLockedTokens.remove(userLock.token);
            } else {
                _normalLockedTokens.remove(userLock.token);
            }
        }
        userLock.withdrawnAmount = unlockAmount;

        _tokenToLockIds[userLock.token].remove(userLock.id);

        IERC20(userLock.token).transfer(msg.sender, unlockAmount);

        emit LockRemoved(
            userLock.id,
            userLock.token,
            msg.sender,
            unlockAmount,
            block.timestamp
        );
    }

    function _vestingUnlock(Lock storage userLock) internal {
        uint256 withdrawable = _withdrawableTokens(userLock);
        uint256 newTotalUnlockAmount = userLock.withdrawnAmount + withdrawable;
        require(
            withdrawable > 0 && newTotalUnlockAmount <= userLock.amount,
            "Nothing to unlock"
        );

        CumulativeLockInfo storage tokenInfo = cumulativeLockInfo[
            userLock.token
        ];
        bool isLpToken = tokenInfo.factory != address(0);

        if (newTotalUnlockAmount == userLock.amount) {
            if (isLpToken) {
                _userLpLockIds[msg.sender].remove(userLock.id);
            } else {
                _userNormalLockIds[msg.sender].remove(userLock.id);
            }
            _tokenToLockIds[userLock.token].remove(userLock.id);
            emit LockRemoved(
                userLock.id,
                userLock.token,
                msg.sender,
                newTotalUnlockAmount,
                block.timestamp
            );
        }

        if (tokenInfo.amount <= withdrawable) {
            tokenInfo.amount = 0;
        } else {
            tokenInfo.amount = tokenInfo.amount - withdrawable;
        }

        if (tokenInfo.amount == 0) {
            if (isLpToken) {
                _lpLockedTokens.remove(userLock.token);
            } else {
                _normalLockedTokens.remove(userLock.token);
            }
        }
        userLock.withdrawnAmount = newTotalUnlockAmount;

        IERC20(userLock.token).transfer(userLock.owner, withdrawable);

        emit LockVested(
            userLock.id,
            userLock.token,
            msg.sender,
            withdrawable,
            userLock.amount,
            block.timestamp
        );
    }

    function withdrawableTokens(
        uint256 lockId
    ) external view returns (uint256) {
        Lock memory userLock = getLockById(lockId);
        return _withdrawableTokens(userLock);
    }

    function getVestingWithdrawableAmount(
        uint256 startDate,
        uint256 endDate,
        uint256 amount,
        uint256 currentDate
    ) internal pure returns (uint256) {
        if (startDate == endDate) {
            return currentDate > endDate ? amount : 0;
        }
        uint256 timeClamp = currentDate;
        if (timeClamp > endDate) {
            timeClamp = endDate;
        }
        if (timeClamp < startDate) {
            timeClamp = startDate;
        }
        uint256 elapsed = timeClamp - startDate;
        uint256 fullPeriod = endDate - startDate;
        return FullMath.mulDiv(amount, elapsed, fullPeriod); // fullPeriod cannot equal zero due to earlier checks and restraints when locking tokens (startEmission < endEmission)
    }

    function _withdrawableTokens(
        Lock memory userLock
    ) internal view returns (uint256) {
        if (userLock.amount == 0) return 0;
        if (userLock.withdrawnAmount >= userLock.amount) return 0;
        if (!userLock.isVesting && block.timestamp < userLock.unlockDate)
            return 0;

        uint256 currentTotalWithdrawable = getVestingWithdrawableAmount(
            userLock.lockDate,
            userLock.unlockDate,
            userLock.amount,
            block.timestamp
        );
        uint256 withdrawable = 0;
        if (currentTotalWithdrawable > userLock.amount) {
            withdrawable = userLock.amount - userLock.withdrawnAmount;
        } else {
            withdrawable = currentTotalWithdrawable - userLock.withdrawnAmount;
        }
        return withdrawable;
    }

    function editLock(
        uint256 lockId,
        uint256 newAmount,
        uint256 newUnlockDate
    ) external payable override validLock(lockId) {
        Lock storage userLock = _locks[_getActualIndex(lockId)];
        require(
            userLock.owner == msg.sender,
            "You are not the owner of this lock"
        );
        require(userLock.withdrawnAmount == 0, "Lock was unlocked");

        uint256 validFee;
        if (!hasRefferalTokenHold(msg.sender)) {
            validFee = gFees.ethEditFee;
        } else {
            validFee = gFees.referralDiscountEthFee;
        }

        require(msg.value == validFee, "SERVICE FEE");

        if (newUnlockDate > 0) {
            require(
                newUnlockDate >= userLock.unlockDate &&
                    newUnlockDate > block.timestamp,
                "New unlock time should not be before old unlock time or current time"
            );
            userLock.unlockDate = newUnlockDate;
        }

        if (newAmount > 0) {
            require(
                newAmount >= userLock.amount,
                "New amount should not be less than current amount"
            );

            uint256 diff = newAmount - userLock.amount;

            if (diff > 0) {
                userLock.amount = newAmount;
                CumulativeLockInfo storage tokenInfo = cumulativeLockInfo[
                    userLock.token
                ];
                tokenInfo.amount = tokenInfo.amount + diff;
                _safeTransferFromEnsureExactAmount(
                    userLock.token,
                    msg.sender,
                    address(this),
                    diff
                );
            }
        }


}
