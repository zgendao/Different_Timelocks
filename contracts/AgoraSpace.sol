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
    struct LockedItem {
        uint256 expires;
        uint256 amount;
        uint8 rankId;
    }
    // Rankings
    struct Rank {
        uint256 minDuration;
        uint256 goalAmount;
        uint8 id;
    }
    //For rankings
    struct Balance {
        uint256 locked;
        uint256 unLocked;
    }

    Rank[] internal ranks;
    //For rankings
    mapping(uint8 => mapping(address => Balance)) public rankBalances;

    mapping(address => LockedItem[]) public timelocks;
    uint256 public lockInterval = 10;

    event Deposit(address indexed wallet, uint256 amount);
    event Withdraw(address indexed wallet, uint256 amount);

    /// @param _tokenAddress The address of the token to be staked, that the contract accepts
    /// @param _stakeTokenAddress The address of the token that's given in return
    constructor(address _tokenAddress, address _stakeTokenAddress) {
        token = _tokenAddress;
        stakeToken = _stakeTokenAddress;
    }

    function addRank(uint256 _minDuration, uint256 _goalAmount) external onlyOwner {
        uint16 ranksLength = ranks.length;
        require(ranksLength < 256, "Too many lengths");
        if (ranksLength >= 1) {
            assert(
                ranks[ranksLength - 1].goalAmount <= _goalAmount,
                "New goal amount should be bigger than previous rank's "
            );

            assert(
                ranks[ranksLength - 1].minDuration <= _minDuration,
                "New rank's duration must be longer than the previous one's  "
            );
        }
        ranks.push(Rank(_minDuration, _goalAmount, ranks.length));
    }

    function modifyRank(
        uint256 _minDuration,
        uint256 _goalAmount,
        uint8 _id
    ) external onlyOwner {
        //id check, új mintDur ellenőrzése jobbról és balról, length >= 1,új goalAmount ellenőrzése jobbról és balról
        uint16 ranksLength = ranks.length;
        require(ranksLength > 0, "Ther is no rank to modify");
        require(_id <= ranksLength - 1, "Rank dosen't exist");

        if (_id > 0) {
            assert(ranks[_id - 1].goalAmount <= _goalAmount, "New goal amount should be bigger than previous rank's ");

            assert(
                ranks[_id - 1].minDuration <= _minDuration,
                "New rank's duration must be longer than the previous one's  "
            );
        } // balról

        if (_id < ranksLength - 2) {
            assert(ranks[_id + 1].goalAmount >= _goalAmount, "New goal amount should be smaller than next rank's ");

            assert(
                ranks[_id + 1].minDuration >= _minDuration,
                "New rank's duration must be shorter than the next one's  "
            );
        } //jobbról

        ranks[_id] = Rank(_minDuration, _goalAmount, _id);
    }

    //TODO Utolsó elem törlése

    /// @notice Accepts tokens, locks them and gives different tokens in return
    /// @dev The depositor should approve the contract to manage stakingTokens
    /// @dev For minting stakeTokens, this contract should be the owner of them
    /// @param _amount The amount to be deposited in the smallest unit of the token
    function deposit(
        uint256 _amount,
        uint8 _rankId,
        bool _consolidate
    ) external {
        require(_amount > 0, "Non-positive deposit amount");
        require(timelocks[msg.sender].length < 600, "Too many consecutive deposits");
        require(ranks.length > 0, "There isn't any rank to deposit to");
        require(_rankId <= ranks.length - 1, "Invalid rank");
        //TODO Consolidate
        LockedItem memory timelockData;
        timelockData.expires = block.timestamp + ranks[_rankId].minDuration * 1 minutes;
        timelockData.amount = _amount;
        timelockData.rankId = _rankId;
        timelocks[msg.sender].push(timelockData);
        rankBalances[_rankId][msg.sender].locked = +_amount;
        IAgoraToken(stakeToken).mint(msg.sender, _amount);
        IERC20(token).transferFrom(msg.sender, address(this), _amount);
        emit Deposit(msg.sender, _amount);
    }

    /// @notice If the timelock is expired, gives back the staked tokens in return for the tokens obtained while depositing
    /// @dev This contract should have sufficient allowance to be able to burn stakeTokens from the user
    /// @dev For burning stakeTokens, this contract should be the owner of them
    /// @param _amount The amount to be withdrawn in the smallest unit of the token
    function withdraw(uint256 _amount, uint8 _rankId) external {
        require(_amount > 0, "Non-positive withdraw amount");
        require(
            IAgoraToken(stakeToken).balanceOf(msg.sender) - getLockedAmount(msg.sender) >= _amount,
            "Not enough unlocked tokens"
        );
        require(rankBalances[_rankId][msg.sender].unlocked >= _amount, "Not enough unlocked tokens in this rank");
        rankBalances[_rankId][msg.sender].unlocked = -_amount;
        IAgoraToken(stakeToken).burn(msg.sender, _amount);
        IERC20(token).transfer(msg.sender, _amount);
        emit Withdraw(msg.sender, _amount);
    }

    /// @notice Sets the timelock interval for new deposits
    /// @param _minutes The desired interval in minutes
    function setLockInterval(uint256 _minutes) external onlyOwner {
        lockInterval = _minutes;
    }

    /// @notice Checks the amount of locked tokens for an account and deletes any expired lock data
    /// @param _investor The address whose tokens should be checked
    /// @return The amount of locked tokens
    function getLockedAmount(address _investor) public returns (uint256) {
        uint256 lockedAmount;
        LockedItem[] storage usersLocked = timelocks[_investor];
        int256 usersLockedLength = int256(usersLocked.length);
        uint256 blockTimestamp = block.timestamp;
        for (int256 i = 0; i < usersLockedLength; i++) {
            if (usersLocked[uint256(i)].expires <= blockTimestamp) {
                //Unlock locked balances
                rankBalances[usersLocked[uint256(i)].rankId][_investor].locked = -usersLocked[uint256(i)].amount;
                rankBalances[usersLocked[uint256(i)].rankId][_investor].unlocked = +usersLocked[uint256(i)].amount;
                // Expired locks, remove them
                usersLocked[uint256(i)] = usersLocked[uint256(usersLockedLength) - 1];
                usersLocked.pop();
                usersLockedLength--;
                i--;
            } else {
                // Still not expired, count it in
                lockedAmount += usersLocked[uint256(i)].amount;
            }
        }
        return lockedAmount;
    }

    //TODO Function Consolidate
}
