pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./OnigiriToken.sol";

contract DevFunds {
    using SafeMath for uint;

    // the ONIGIRI token
    OnigiriToken public onigiri;
    // dev address to receive onigiri
    address public devaddr;
    // last withdraw block, use block 1 as default
    uint public lastWithdrawBlock = 1;
    // withdraw interval ~ 2 weeks
    uint public constant WITHDRAW_INTERVAL = 89600;

    constructor(OnigiriToken _onigiri, address _devaddr) public {
        require(address(_onigiri) != address(0) && _devaddr != address(0), "invalid address");
        onigiri = _onigiri;
        devaddr = _devaddr;
    }

    function withdraw() public {
        uint unlockBlock = lastWithdrawBlock.add(WITHDRAW_INTERVAL);
        require(block.number >= unlockBlock, "onigiri locked");
        uint _amount = onigiri.balanceOf(address(this));
        require(_amount > 0, "zero onigiri amount");
        lastWithdrawBlock = block.number;
        onigiri.transfer(devaddr, _amount);
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
    }
}