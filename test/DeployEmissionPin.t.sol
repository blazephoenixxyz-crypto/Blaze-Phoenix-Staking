// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  script/Deploy.s.sol funds the emission from its own constant, EMISSION. The
//  contract caps funding at TOTAL_REWARDS. The two are separate numbers that
//  answer the same question today; they are pinned, not fused:
//    - the script's amount equals the contract's cap, by value;
//    - pinEmission refuses any other value, one wei either side included;
//    - a full run refuses to fund when the deployed contract reports a
//      different cap, so the pin is wired into run(), not only defined.
//  Mutants: .github/scripts/mutants.py, "Deploy: ..." entries.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixStaking} from "../src/BlazePhoenixStaking.sol";
import {Deploy} from "../script/Deploy.s.sol";

contract DeployPinToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

contract DeployEmissionPinTest is Test {
    bytes constant PIN_ERR = bytes("Deploy: EMISSION != TOTAL_REWARDS()");
    uint256 constant PK = 0xB2D0C5;

    Deploy d;
    DeployPinToken token;
    address deployer;
    address treasury = address(0x7EA5);

    function setUp() public {
        d = new Deploy();
        token = new DeployPinToken();
        deployer = vm.addr(PK);
        vm.setEnv("BZPX_ADDRESS", vm.toString(address(token)));
        vm.setEnv("TREASURY_ADDRESS", vm.toString(treasury));
        vm.setEnv("PRIVATE_KEY", vm.toString(PK));
    }

    function _cap() internal returns (uint256) {
        return new BlazePhoenixStaking(address(token), treasury).TOTAL_REWARDS();
    }

    function test_DeployEmissionEqualsTotalRewards() public {
        uint256 cap = _cap();
        assertEq(d.EMISSION(), cap, "script amount != contract cap");
        assertEq(d.pinEmission(cap), cap, "pin does not return the cap");
    }

    function test_PinEmissionRefusesOneWeiEitherSide() public {
        uint256 cap = _cap();
        vm.expectRevert(PIN_ERR);
        d.pinEmission(cap - 1);
        vm.expectRevert(PIN_ERR);
        d.pinEmission(cap + 1);
        vm.expectRevert(PIN_ERR);
        d.pinEmission(0);
    }

    function testFuzz_PinEmissionRefusesAnyOtherValue(uint256 x) public {
        vm.assume(x != d.EMISSION());
        vm.expectRevert(PIN_ERR);
        d.pinEmission(x);
    }

    function test_DeployRunFundsTheFullEmission() public {
        uint256 cap = _cap();
        token.mint(deployer, cap);
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        d.run();
        BlazePhoenixStaking s = BlazePhoenixStaking(predicted);
        assertEq(s.rewardReserve(), cap, "reserve != cap");
        assertEq(s.totalEmissionFunded(), cap, "funded != cap");
        assertEq(token.balanceOf(deployer), 0, "deployer kept a remainder");
    }

    function test_DeployRunRefusesWhenTheDeployedCapDiffers() public {
        uint256 cap = _cap();
        token.mint(deployer, cap + 1);
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        vm.mockCall(predicted, abi.encodeWithSignature("TOTAL_REWARDS()"), abi.encode(cap + 1));
        vm.etch(predicted, ""); // mockCall gives a codeless target a placeholder; clear it so CREATE lands
        vm.expectRevert(PIN_ERR);
        d.run();
    }
}
