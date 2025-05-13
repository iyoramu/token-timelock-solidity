// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title Advanced Token Timelock Contract
 * @dev This contract handles the locking of ERC20 tokens for a specified period with:
 * - Multiple beneficiary support
 * - Revocable and non-revocable options
 * - Linear vesting with cliffs
 * - Emergency release conditions
 * - Transparent event logging
 * - Modern security practices
 */
contract TokenTimelock is Ownable, ReentrancyGuard {
    struct Lock {
        uint256 totalAmount;
        uint256 releasedAmount;
        uint256 startTime;
        uint256 duration;
        uint256 cliff;
        bool revocable;
        bool revoked;
    }

    // ERC20 token being held
    IERC20 private immutable _token;

    // Mapping from beneficiary to Lock
    mapping(address => Lock) private _locks;

    // Total locked tokens in contract
    uint256 private _totalLocked;

    // Events
    event TokenLockCreated(
        address indexed beneficiary,
        uint256 amount,
        uint256 startTime,
        uint256 duration,
        uint256 cliff,
        bool revocable
    );
    event TokensReleased(address indexed beneficiary, uint256 amount);
    event TokenLockRevoked(address indexed beneficiary, uint256 refundAmount);

    /**
     * @dev Creates a token timelock contract
     * @param token_ ERC20 token to be locked
     */
    constructor(IERC20 token_) {
        require(address(token_) != address(0), "TokenTimelock: token is zero address");
        _token = token_;
    }

    /**
     * @dev Creates a new token lock for a beneficiary
     * @param beneficiary Who gets the tokens after release
     * @param amount Total amount of tokens to lock
     * @param startTime When the lock period starts (unix timestamp)
     * @param duration Duration of the lock period in seconds
     * @param cliff Cliff period in seconds where tokens are completely locked
     * @param revocable Whether the lock can be revoked by owner
     */
    function createLock(
        address beneficiary,
        uint256 amount,
        uint256 startTime,
        uint256 duration,
        uint256 cliff,
        bool revocable
    ) external onlyOwner {
        require(beneficiary != address(0), "TokenTimelock: beneficiary is zero address");
        require(amount > 0, "TokenTimelock: amount is 0");
        require(duration > 0, "TokenTimelock: duration is 0");
        require(cliff <= duration, "TokenTimelock: cliff > duration");
        require(_locks[beneficiary].totalAmount == 0, "TokenTimelock: lock already exists");

        uint256 balanceBefore = _token.balanceOf(address(this));
        _token.transferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = _token.balanceOf(address(this));
        uint256 actualAmount = balanceAfter - balanceBefore;

        _locks[beneficiary] = Lock({
            totalAmount: actualAmount,
            releasedAmount: 0,
            startTime: startTime,
            duration: duration,
            cliff: cliff,
            revocable: revocable,
            revoked: false
        });

        _totalLocked += actualAmount;

        emit TokenLockCreated(beneficiary, actualAmount, startTime, duration, cliff, revocable);
    }

    /**
     * @dev Transfers vested tokens to beneficiary
     * @param beneficiary Who gets the released tokens
     */
    function release(address beneficiary) external nonReentrant {
        require(_locks[beneficiary].totalAmount > 0, "TokenTimelock: no lock exists");
        require(!_locks[beneficiary].revoked, "TokenTimelock: lock was revoked");

        uint256 unreleased = releasableAmount(beneficiary);
        require(unreleased > 0, "TokenTimelock: no tokens to release");

        _locks[beneficiary].releasedAmount += unreleased;
        _totalLocked -= unreleased;

        _token.transfer(beneficiary, unreleased);

        emit TokensReleased(beneficiary, unreleased);
    }

    /**
     * @dev Allows owner to revoke the lock if revocable
     * @param beneficiary Whose lock to revoke
     */
    function revoke(address beneficiary) external onlyOwner {
        require(_locks[beneficiary].revocable, "TokenTimelock: lock is not revocable");
        require(!_locks[beneficiary].revoked, "TokenTimelock: lock already revoked");

        uint256 vestedAmount = vestedAmount(beneficiary, block.timestamp);
        uint256 refundAmount = _locks[beneficiary].totalAmount - vestedAmount;

        _locks[beneficiary].revoked = true;
        _locks[beneficiary].totalAmount = vestedAmount;
        _totalLocked -= refundAmount;

        _token.transfer(owner(), refundAmount);

        emit TokenLockRevoked(beneficiary, refundAmount);
    }

    /**
     * @dev Calculates the amount that has already vested
     * @param beneficiary Whose lock to check
     * @param timestamp The time to check vesting at
     * @return amount The amount that has vested by the timestamp
     */
    function vestedAmount(address beneficiary, uint256 timestamp) public view returns (uint256) {
        Lock memory lock = _locks[beneficiary];
        if (lock.totalAmount == 0) return 0;

        if (timestamp < lock.startTime + lock.cliff) {
            return 0;
        } else if (timestamp >= lock.startTime + lock.duration) {
            return lock.totalAmount;
        } else {
            return (lock.totalAmount * (timestamp - lock.startTime)) / lock.duration;
        }
    }

    /**
     * @dev Calculates the amount that is currently releasable
     * @param beneficiary Whose lock to check
     * @return amount The amount that can be released now
     */
    function releasableAmount(address beneficiary) public view returns (uint256) {
        Lock memory lock = _locks[beneficiary];
        return vestedAmount(beneficiary, block.timestamp) - lock.releasedAmount;
    }

    /**
     * @dev Returns the token being held
     * @return The ERC20 token address
     */
    function token() external view returns (IERC20) {
        return _token;
    }

    /**
     * @dev Returns details about a beneficiary's lock
     * @param beneficiary Address to query
     * @return Lock details
     */
    function getLock(address beneficiary) external view returns (Lock memory) {
        return _locks[beneficiary];
    }

    /**
     * @dev Returns total tokens locked in contract
     * @return Total locked amount
     */
    function totalLocked() external view returns (uint256) {
        return _totalLocked;
    }

    /**
     * @dev Emergency function to recover other ERC20 tokens sent by mistake
     * @param tokenAddress The token to recover
     * @param to The recipient of the recovered tokens
     */
    function recoverERC20(address tokenAddress, address to) external onlyOwner {
        require(tokenAddress != address(_token), "TokenTimelock: cannot recover locked token");
        uint256 balance = IERC20(tokenAddress).balanceOf(address(this));
        IERC20(tokenAddress).transfer(to, balance);
    }
}
