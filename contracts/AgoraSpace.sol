// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "./token/IAgoraToken.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title A contract for staking tokens
contract AgoraSpace is Ownable {
    // Tokens managed by the contract
    address public immutable token;
    address public immutable stakeToken;

    // For timelock
    mapping(address => LockedItem[]) public timelocks;

    struct LockedItem {
        uint256 expires;
        uint256 amount;
        uint8 rankId;
    }
    // For ranking
    struct Rank {
        uint256 minDuration;
        uint256 goalAmount;
        uint8 id;
    }
    //For storing balances
    struct Balance {
        uint256 locked;
        uint256 unLocked;
    }
    // Lowest -> Highest
    Rank[] internal ranks;

    mapping(uint8 => mapping(address => Balance)) public rankBalances;

    event Deposit(address indexed wallet, uint256 amount);
    event Withdraw(address indexed wallet, uint256 amount);
    event NewRank(uint256 minDuration, uint256 goalAmount, uint8 id);
    event ModifyRank(uint256 minDuration, uint256 goalAmount, uint8 id);

    /// @param _tokenAddress The address of the token to be staked, that the contract accepts
    /// @param _stakeTokenAddress The address of the token that's given in return
    constructor(address _tokenAddress, address _stakeTokenAddress) {
        token = _tokenAddress;
        stakeToken = _stakeTokenAddress;
    }

    /// @notice Creats a new rank
    /// @dev Only the new highest rank can be added
    /// @dev The goal amount and the lock time have to be atleast same amount as the previus one
    /// @param _minDuration The duration of the lock
    /// @param _goalAmount The amount of tokens needed to reach the rank
    function addRank(uint256 _minDuration, uint256 _goalAmount) external onlyOwner {
        uint16 ranksLength = ranks.length;
        require(ranksLength < 256, "Too many lengths");
        if (ranksLength >= 1) {
            assert(
                ranks[ranksLength - 1].goalAmount <= _goalAmount,
                "New goal amount can't be smaller than previous rank's "
            );

            assert(
                ranks[ranksLength - 1].minDuration <= _minDuration,
                "New rank's duration can't be shorter than the previous one's  "
            );
        }
        ranks.push(Rank(_minDuration, _goalAmount, ranksLength));
        emit NewRank(_minDuration, _goalAmount, ranksLength);
    }

    /// @notice Modifies a new rank
    /// @dev Values must be between of the previus and the next ranks'
    /// @param _minDuration New duration of the lock
    /// @param _goalAmount New amount of tokens needed to reach the rank
    /// @param _id The id of the rank to be modified
    function modifyRank(
        uint256 _minDuration,
        uint256 _goalAmount,
        uint8 _id
    ) external onlyOwner {
        uint16 ranksLength = ranks.length;
        require(ranksLength > 0, "Ther is no rank to modify");
        require(_id <= ranksLength - 1, "Rank dosen't exist");

        if (_id > 0) {
            assert(ranks[_id - 1].goalAmount <= _goalAmount, "New goal amount should be bigger than previous rank's ");

            assert(
                ranks[_id - 1].minDuration <= _minDuration,
                "New rank's duration must be longer than the previous one's  "
            );
        }

        if (_id < ranksLength - 2) {
            assert(ranks[_id + 1].goalAmount >= _goalAmount, "New goal amount should be smaller than next rank's ");

            assert(
                ranks[_id + 1].minDuration >= _minDuration,
                "New rank's duration must be shorter than the next one's  "
            );
        }

        ranks[_id] = Rank(_minDuration, _goalAmount, _id);
        emit ModifyRank(_minDuration, _goalAmount, _id);
    }

    /// @notice Accepts tokens, locks them and gives different tokens in return
    /// @dev The depositor should approve the contract to manage stakingTokens
    /// @dev For minting stakeTokens, this contract should be the owner of them
    /// @param _amount The amount to be deposited in the smallest unit of the token
    /// @param _rankId The id of the rank to be deposited to
    /// @param _consolidate Calls the consolidate function if true
    function deposit(
        uint256 _amount,
        uint8 _rankId,
        bool _consolidate
    ) external {
        require(_amount > 0, "Non-positive deposit amount");
        require(timelocks[msg.sender].length < 600, "Too many consecutive deposits");
        require(ranks.length > 0, "There isn't any rank to deposit to");
        require(_rankId <= ranks.length - 1, "Invalid rank");

        if (
            rankBalances[_rankId][msg.sender].unLocked + rankBalances[_rankId][msg.sender].locked + _amount >=
            ranks[_rankId].goalAmount
        ) {
            unlockBelow(_rankId, msg.sender);
        } else if (_consolidate && ranks.length > 0) {
            consolidate(_amount, _rankId, msg.sender);
        }

        LockedItem memory timelockData;
        timelockData.expires = block.timestamp + ranks[_rankId].minDuration * 1 minutes;
        timelockData.amount = _amount;
        timelockData.rankId = _rankId;
        timelocks[msg.sender].push(timelockData);
        rankBalances[_rankId][msg.sender].locked += _amount;
        IAgoraToken(stakeToken).mint(msg.sender, _amount);
        IERC20(token).transferFrom(msg.sender, address(this), _amount);
        emit Deposit(msg.sender, _amount);
    }

    /// @notice If the timelock is expired, gives back the staked tokens in return for the tokens obtained while depositing
    /// @dev This contract should have sufficient allowance to be able to burn stakeTokens from the user
    /// @dev For burning stakeTokens, this contract should be the owner of them
    /// @param _amount The amount to be withdrawn in the smallest unit of the token
    /// @param _rankId The id of the rank to be withdrawn from
    function withdraw(uint256 _amount, uint8 _rankId) external {
        require(_amount > 0, "Non-positive withdraw amount");
        unlockExpired(msg.sender);
        require(rankBalances[_rankId][msg.sender].unlocked >= _amount, "Not enough unlocked tokens in this rank");
        rankBalances[_rankId][msg.sender].unlocked -= _amount;
        IAgoraToken(stakeToken).burn(msg.sender, _amount);
        IERC20(token).transfer(msg.sender, _amount);
        emit Withdraw(msg.sender, _amount);
    }

    /// @notice Checks the locked tokens for an account and unlocks them if they're expired
    /// @param _investor The address whose tokens should be checked
    function unlockExpired(address _investor) public {
        uint256 lockedAmount;
        uint8 ranksLength = ranks.length - 1;
        mapping(uint8 => uint256) memory expired;
        LockedItem[] storage usersLocked = timelocks[_investor];
        int256 usersLockedLength = int256(usersLocked.length);
        uint256 blockTimestamp = block.timestamp;
        for (int256 i = 0; i < usersLockedLength; i++) {
            if (usersLocked[uint256(i)].expires <= blockTimestamp) {
                //Collect expired amounts per ranks
                expired[usersLocked[uint256(i)].rankId] += usersLocked[uint256(i)].amount;
                // Expired locks, remove them
                usersLocked[uint256(i)] = usersLocked[uint256(usersLockedLength) - 1];
                usersLocked.pop();
                usersLockedLength--;
                i--;
            }
        }
        // Moving expired amounts from locked to unlocked
        for (uint8 i = 0; i <= ranksLength; i++) {
            rankBalances[i][_investor].locked -= expired[i];
            rankBalances[i][_investor].unlocked += expired[i];
        }
    }

    /// @notice Sums the locked tokens for an account by ranks if they were expired
    /// @param _investor The address whose tokens should be checked
    /// @param _rankId The id of the rank to be checked
    /// @return The total amount of expired but not unlocked tokens in the rank
    function viewExpired(address _investor, uint8 _rankId) public view returns (uint256) {
        uint256 expiredAmount;
        LockedItem[] memory usersLocked = timelocks[_investor];
        int256 usersLockedLength = int256(usersLocked.length);
        uint256 blockTimestamp = block.timestamp;
        for (uint256 i = 0; i < usersLockedLength; i++) {
            if (usersLocked[i].rankId == _rankId && usersLocked[i].expires <= blockTimestamp) {
                expiredAmount += usersLocked[i].amount;
            }
        }
        return expiredAmount;
    }

    /// @notice Unlocks every deposite below a certan rank
    /// @dev Should be called, when the minimum of a rank is reached
    /// @param _investor The address whose tokens should be checked
    /// @param _rankId The id of the rank to be checked
    function unlockBelow(uint8 _rankId, address _investor) internal {
        LockedItem[] storage usersLocked = timelocks[_investor];
        int256 usersLockedLength = int256(usersLocked.length);
        mapping(uint8 => uint256) memory unLocked;
        uint8 ranksLength = ranks.length - 1;

        for (uint8 i = 0; i < _rankId; i++) {
            if (rankBalances[i][_investor].locked > 0) {
                for (int256 i = 0; i < usersLockedLength; i++) {
                    if (usersLocked[uint256(i)].rankId < _rankId) {
                        //Collet the amount to be unlocked per rank
                        unLocked[usersLocked[uint256(i)].rankId] += usersLocked[uint256(i)].amount;
                        // Expired locks, remove them
                        usersLocked[uint256(i)] = usersLocked[uint256(usersLockedLength) - 1];
                        usersLocked.pop();
                        usersLockedLength--;
                        i--;
                    }
                }
                break;
            }
        }
        // Moving unlocked amounts from locked to unlocked
        for (uint8 i = 0; i <= ranksLength; i++) {
            rankBalances[i][_investor].locked -= unLocked[i];
            rankBalances[i][_investor].unlocked += unLocked[i];
        }
    }

    /// @notice Collects the investments up to a certain rank if its needed to reach the minimum
    /// @dev There must be more than 1 rank
    /// @dev The minimum should not be reached with the new deposit
    /// @dev The deposited amount must be locked after the function call
    /// @param _amount The amount to be deposited
    /// @param _rankId The id of the rank to be deposited to
    /// @param _investor The address which made the deposit
    function consolidate(
        uint256 _amount,
        uint8 _rankId,
        address _investor
    ) internal {
        uint256 consolidateAmount = ranks[_rankId].goalAmount -
            rankBalances[_rankId][_investor].unlocked -
            rankBalances[_rankId][_investor].locked -
            _amount;
        uint256 totalBalanceBelow;

        uint256 lockedBalance;
        uint256 unLockedBalance;

        LockedItem[] storage usersLocked = timelocks[_investor];
        int256 usersLockedLength = int256(usersLocked.length);

        for (uint8 i = 0; i < _rankId; i++) {
            lockedBalance = rankBalances[i][_investor].locked;
            unlockedBalance = rankBalances[i][_investor].unlocked;

            if (lockedBalance > 0) {
                totalBalanceBelow = +lockedBalance;
                rankBalances[i][_investor].locked = 0;
            }

            if (unlockedBalance > 0) {
                totalBalanceBelow = +unlockedBalance;
                rankBalances[i][_investor].unlocked = 0;
            }
        }

        if (totalBalanceBelow > 0) {
            LockedItem memory timelockData;
            // Iterate over the locked list, and unlocks everything below the rank
            for (int256 i = 0; i < usersLockedLength; i++) {
                if (usersLocked[uint256(i)].rankId < _rankId) {
                    usersLocked[uint256(i)] = usersLocked[uint256(usersLockedLength) - 1];
                    usersLocked.pop();
                    usersLockedLength--;
                    i--;
                }
            }
            if (totalBalanceBelow > consolidateAmount) {
                //Create a new locked item, with the value of consolidateAmount and lock it, for the rank's duration
                timelockData.expires = block.timestamp + ranks[_rankId].minDuration * 1 minutes;
                timelockData.amount = consolidateAmount;
                timelockData.rankId = _rankId;
                timelocks[_investor].push(timelockData);
                rankBalances[_rankId][_investor].locked += consolidateAmount;
                rankBalances[_rankId][_investor].unlocked += totalBalanceBelow - consolidateAmount;
            } else {
                //Create a new locked item, with the value of totalBalanceBelow and lock it, for the rank's duration
                timelockData.expires = block.timestamp + ranks[_rankId].minDuration * 1 minutes;
                timelockData.amount = totalBalanceBelow;
                timelockData.rankId = _rankId;
                timelocks[_investor].push(timelockData);

                rankBalances[_rankId][_investor].locked += totalBalanceBelow;
            }
        }
    }
}
