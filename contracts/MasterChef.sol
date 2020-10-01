pragma solidity 0.6.12;


import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./OnigiriToken.sol";


interface IMigratorChef {
    // Perform LP token migration from legacy UniswapV2 to OnigiriSwap.
    // Take the current LP token address and return the new LP token address.
    // Migrator should have full access to the caller's LP token.
    // Return the new LP token address.
    //
    // XXX Migrator must have allowance access to UniswapV2 LP tokens.
    // OnigiriSwap must mint EXACTLY the same amount of OnigiriSwap LP tokens or
    // else something bad will happen. Traditional UniswapV2 does not
    // do that so be careful!
    function migrate(IERC20 token) external returns (IERC20);
}

// MasterChef is the master of Onigiri. He can make Onigiri and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once ONIGIRI is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChef is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of ONIGIRIs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accOnigiriPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accOnigiriPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. ONIGIRIs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that ONIGIRIs distribution occurs.
        uint256 accOnigiriPerShare; // Accumulated ONIGIRIs per share, times 1e12. See below.
    }

    // The ONIGIRI TOKEN!
    OnigiriToken public onigiri;
    // Dev address.
    address public devaddr;
    // Bonus muliplier for early onigiri makers.
    uint256 public constant BONUS_MULTIPLIER = 4;
    // The migrator contract. It has a lot of power. Can only be set through governance (owner).
    IMigratorChef public migrator;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation poitns. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when ONIGIRI mining starts.
    uint256 public startBlock;

    uint256 public constant INITIAL_ONIGIRI_PER_BLOCK = 20e18; // 20 per block
    uint256 public constant HALVING_PERIOD = 100_000; // 100000 block (around 2 weeks)

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    constructor(
        OnigiriToken _onigiri,
        address _devaddr,
        uint256 _startBlock
    ) public {
        onigiri = _onigiri;
        devaddr = _devaddr;
        startBlock = _startBlock;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IERC20 _lpToken, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accOnigiriPerShare: 0
        }));
    }

    // Update the given pool's ONIGIRI allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Set the migrator contract. Can only be called by the owner.
    function setMigrator(IMigratorChef _migrator) public onlyOwner {
        migrator = _migrator;
    }

    // Migrate lp token to another lp contract. Can be called by anyone. We trust that migrator contract is good.
    function migrate(uint256 _pid) public {
        require(address(migrator) != address(0), "migrate: no migrator");
        PoolInfo storage pool = poolInfo[_pid];
        IERC20 lpToken = pool.lpToken;
        uint256 bal = lpToken.balanceOf(address(this));
        lpToken.safeApprove(address(migrator), bal);
        IERC20 newLpToken = migrator.migrate(lpToken);
        require(bal == newLpToken.balanceOf(address(this)), "migrate: bad");
        pool.lpToken = newLpToken;
    }

    // Return total reward of Onigiri over the given _from to _to block.
    // Suppose the difference can only be at maximum 1 epoch (2 weeks)
    function getRewardDuringPeriod(uint256 _from, uint256 _to) public view returns (uint256) {
        uint256 epoch_from = _from.sub(startBlock).div(HALVING_PERIOD);
        uint256 epoch_to = _to.sub(startBlock).div(HALVING_PERIOD);

        if (epoch_from == epoch_to) {
            return _to.sub(_from).mul(getRewardPerBlock(_from));
        } else {
            uint256 boundary = HALVING_PERIOD.mul(epoch_to).add(startBlock);
            uint256 first = boundary.sub(_from).mul(getRewardPerBlock(_from));
            uint256 second = _to.sub(boundary).mul(getRewardPerBlock(_to));
            return first.add(second);
        }
    }

    // Return Onigiri reward of a given block height
    function getRewardPerBlock(uint256 blockIndex) private view returns (uint256) {
        uint256 epoch = blockIndex.sub(startBlock).div(HALVING_PERIOD);
        if (epoch == 0) {
            return INITIAL_ONIGIRI_PER_BLOCK * BONUS_MULTIPLIER; // 80
        } else if (epoch == 1) {
            return INITIAL_ONIGIRI_PER_BLOCK * BONUS_MULTIPLIER; // 80
        } else if (epoch == 2) {
            return INITIAL_ONIGIRI_PER_BLOCK; // 20
        } else if (epoch == 3) {
            return INITIAL_ONIGIRI_PER_BLOCK / 2; // 10
        } else if (epoch == 4) {
            return INITIAL_ONIGIRI_PER_BLOCK / 4; // 5
        } else if (epoch == 5) {
            return INITIAL_ONIGIRI_PER_BLOCK / 8; // 2.5
        } else if (epoch == 6) {
            return INITIAL_ONIGIRI_PER_BLOCK / 16; // 1.25
        } else if (epoch == 7) {
            return INITIAL_ONIGIRI_PER_BLOCK / 32; // 0.625
        } else {
            return INITIAL_ONIGIRI_PER_BLOCK / 64; // 0.3125
        }
    }

    // View function to see pending ONIGIRIs on frontend.
    function pendingOnigiri(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accOnigiriPerShare = pool.accOnigiriPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 totalOnigiriReward = getRewardDuringPeriod(pool.lastRewardBlock, block.number);
            uint256 onigiriReward = totalOnigiriReward.mul(pool.allocPoint).div(totalAllocPoint);
            accOnigiriPerShare = accOnigiriPerShare.add(onigiriReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accOnigiriPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 totalOnigiriReward = getRewardDuringPeriod(pool.lastRewardBlock, block.number);
        uint256 onigiriReward = totalOnigiriReward.mul(pool.allocPoint).div(totalAllocPoint);
        uint currentBlockNumber = block.number;
        uint256 epoch = currentBlockNumber.sub(startBlock).div(HALVING_PERIOD);
        if (epoch <= 1) {
            onigiri.mint(devaddr, onigiriReward.div(15));
        } else {
            onigiri.mint(devaddr, onigiriReward.div(30));
        }
        onigiri.mint(address(this), onigiriReward);
        pool.accOnigiriPerShare = pool.accOnigiriPerShare.add(onigiriReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for ONIGIRI allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accOnigiriPerShare).div(1e12).sub(user.rewardDebt);
            if(pending > 0) {
                safeOnigiriTransfer(msg.sender, pending);
            }
        }
        if(_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accOnigiriPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accOnigiriPerShare).div(1e12).sub(user.rewardDebt);
        if(pending > 0) {
            safeOnigiriTransfer(msg.sender, pending);
        }
        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accOnigiriPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
    }

    // Safe onigiri transfer function, just in case if rounding error causes pool to not have enough ONIGIRIs.
    function safeOnigiriTransfer(address _to, uint256 _amount) internal {
        uint256 onigiriBal = onigiri.balanceOf(address(this));
        if (_amount > onigiriBal) {
            onigiri.transfer(_to, onigiriBal);
        } else {
            onigiri.transfer(_to, _amount);
        }
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
    }
}
