defmodule VoxelRegion.CircuitTest do
  use ExUnit.Case,async: true
  @moduletag :b5
  alias VoxelRegion.{Circuit,Damage}

  # 只测试：目录值与发布目录同口径——铜 σ 5.8e7、k 4000；电阻合金 σ 4、λ 0.2；开关 41（闭合同铜）；
  # 蓄能石 42 σ 20、每米 24 V、每宏格 10 MJ；热电石 43 σ 2、k 15、S 0.05 V/K。线截面、面厚 = 发布值。
  # 期望逐项按 r = d/(σA)（接触边两侧各半格）与 KCL 手算。
  # 容差：同一回路里铜—铜接触半格 8.6e-9 Ω（电导 1.2e8 S）与合金／电池半格 0.025–0.125 Ω 相差 ~1e7，
  # 消元的相对误差 ≈ κ·ε ≈ 1e7 × 2.2e-16 ≈ 3e-9，所以电流按 1e-8 相对容差比较。
  @rel 1.0e-8
  @section 3.814697265625e-06
  @cu 5.8e7
  @ambient 293.15
  defp catalog do
    %{materials: %{11=>%{},
        24=>%{"electrical_conductivity"=>@cu,"thermal_conductivity"=>4000},
        40=>%{"electrical_conductivity"=>4.0,"luminous_fraction"=>0.2,"thermal_conductivity"=>25},
        41=>%{"electrical_conductivity"=>@cu,"circuit_switch"=>true,"thermal_conductivity"=>4000},
        42=>%{"electrical_conductivity"=>20.0,"battery_volts_per_m"=>24.0,"battery_energy_per_macro_j"=>1.0e7,"thermal_conductivity"=>25},
        43=>%{"electrical_conductivity"=>2.0,"seebeck_v_per_k"=>0.05,"thermal_conductivity"=>15}},
      attachments: %{"line_section_m2"=>@section,"face_thickness_m"=>1/512}}
  end
  defp macro({x,y,z},material),do: %{micro: {x*8,y*8,z*8},granularity: 0,material: material,owner: {0,0},incarnation: 1}
  defp key(t),do: VoxelRegion.ThermalGeometry.key(t)
  # 相邻宏格两两一条接触（面积 1 m²），按列表顺序。
  defp contacts(cells) do
    for {a,i}<-Enum.with_index(cells),{b,j}<-Enum.with_index(cells),i<j,adjacent?(a,b),do: {a,b,1.0}
  end
  defp adjacent?(a,b) do
    d=Enum.zip(Tuple.to_list(a.micro),Tuple.to_list(b.micro)) |> Enum.map(fn {p,q}->abs(p-q) end)
    Enum.sort(d)==[0,0,8]
  end
  defp run(cells,damage \\ %{},duration \\ 0.5,slots \\ %{},hosts \\ %{}) do
    input=Circuit.prepare(slots,damage,catalog(),duration,%{"ambient_kelvin"=>@ambient})
    Circuit.plan(input,hosts,contacts(cells))
  end
  defp stored(t,joules),do: {Damage.key(t),Map.put(t,:stored_j,joules)}
  defp hot(t,kelvin),do: {Damage.key(t),Map.put(t,:temperature_kelvin,kelvin)}
  # 半格电阻：宏格 0.5 m / (σ × 1 m²)。
  defp half(sigma),do: 0.5/sigma

  # 竖直回路（z = 0）：x = 0 列自下而上 铜 (0,0)、电池 (0,1)、电池/铜 (0,2)、铜 (0,3)；顶行 (1,3)(2,3) 铜；
  # x = 2 列 (2,2) 铜、(2,1) 负载、(2,0) 铜；底行 (1,0) 铜。十条接触边围成一圈，中间 (1,1)(1,2) 是空气。
  defp loop(second \\ 42,load \\ 40) do
    [macro({0,0,0},24),macro({0,1,0},42),macro({0,2,0},second),macro({0,3,0},24),macro({1,3,0},24),
     macro({2,3,0},24),macro({2,2,0},24),macro({2,1,0},load),macro({2,0,0},24),macro({1,0,0},24)]
  end
  # 回路电阻：每块蓄能石 2 × 0.025 Ω，合金 2 × 0.125 Ω，其余每个铜半格 0.5/σ_Cu（十条边二十个半格）。
  defp loop_r(batteries,copper_halves),do: batteries*2*half(20.0)+2*half(4.0)+copper_halves*half(@cu)

  test "准备与求解只消费目录与导体摘要，不接收或返回世界" do
    cells=loop()
    [_,b1,b2|_]=cells
    plan=run(cells,Map.new([stored(b1,1.0e6),stored(b2,1.0e6)]))
    refute Map.has_key?(plan,:state)
    assert plan.powers[key(Enum.at(cells,7))]>0.0
    assert Map.keys(plan.sources) |> Enum.sort()==Enum.sort([key(b1),key(b2)])
  end

  test "两块蓄能石串联给 2E：I = 48/(2 × 0.05 + 0.25 + 14 个铜半格)；单块 24 V 对照；放电功率 = E·I，热 + 光 = 放电" do
    cells=loop()
    [_,b1,b2|_]=cells
    plan=run(cells,Map.new([stored(b1,1.0e6),stored(b2,1.0e6)]),0.5)
    i=48.0/loop_r(2,14)
    for b<-[b1,b2] do
      s=plan.sources[key(b)]
      assert_in_delta s.current_a,i,i*@rel
      assert s.emf_v==24.0
      assert_in_delta s.stored_j,1.0e6-24.0*i*0.5,24.0*i*0.5*@rel
    end
    assert_in_delta plan.supplied_j,48.0*i*0.5,48.0*i*0.5*@rel
    assert plan.charged_j==0.0
    # 焦耳热按 Σ i²r 记、放电按 Σ ε·i 记：两者只在精确解上相等（Tellegen），数值差同为 κ·ε 量级。
    assert_in_delta Enum.sum(Map.values(plan.powers))*0.5+plan.light_j,plan.supplied_j,plan.supplied_j*@rel
    # 合金整格 I² × 0.25 Ω，其中 0.2 成为光。
    assert_in_delta plan.light_j,0.2*i*i*2*half(4.0)*0.5,0.2*i*i*2*half(4.0)*0.5*3*@rel
    # 对照：上面一块换成铜，只剩 24 V、一块电池的内阻（铜半格 16 个）。
    [_,b|_]=single=loop(24)
    one=run(single,Map.new([stored(b,1.0e6)]))
    assert_in_delta one.sources[key(b)].current_a,24.0/loop_r(1,16),24.0/loop_r(1,16)*@rel
  end

  test "两块相同蓄能石并联：环路电动势相抵，无环流（消元舍入 ≤ 1e-6 A，短路电流 480 A 的 2e-9），储能不变" do
    # 底行 (0,0)(1,0) 铜，中行 (0,1)(1,1) 电池，顶行 (0,2)(1,2) 铜；电池只经 ±Y 面导电，彼此侧面不接触。
    [c0,c1,b0,b1,t0,t1]=cells=[macro({0,0,0},24),macro({1,0,0},24),macro({0,1,0},42),macro({1,1,0},42),
      macro({0,2,0},24),macro({1,2,0},24)]
    plan=run(cells,Map.new([stored(b0,5.0e6),stored(b1,1.0e6)]))
    for b<-[b0,b1],do: assert(abs(plan.sources[key(b)].current_a)<=1.0e-6)
    assert plan.supplied_j<=24*1.0e-6*0.5
    assert_in_delta plan.sources[key(b0)].stored_j,5.0e6,1.0e-3
    # 对照：只把一块翻成放电负载（右边换成合金）就有 24 V/0.3 Ω 量级的电流。
    loaded=run([c0,c1,b0,macro({1,1,0},40),t0,t1],Map.new([stored(b0,5.0e6)]))
    assert_in_delta loaded.sources[key(b0)].current_a,24.0/(2*half(20.0)+2*half(4.0)+8*half(@cu)),1.0e-6
    # 侧面相邻的电池之间没有边：接触摘要里有 (b0,b1)，求解图里没有。
    assert {b0,b1,1.0} in contacts(cells)
    assert Enum.all?([c0,c1,t0,t1],&(not Map.has_key?(plan.sources,key(&1))))
  end

  test "开关断开：电池串悬空，严格 0 A；闭合按欧姆定律" do
    cells=loop(42,41)
    [_,b1,b2|_]=cells
    switch=Enum.at(cells,7)
    loaded=Map.new([stored(b1,1.0e6),stored(b2,1.0e6)])
    # 断开的开关不是导体：World 的接触摘要（solid_contacts 按 sigma）里没有它，两侧的铜悬空。
    assert Circuit.solid_contacts([{switch,64}],catalog(),loaded)==%{}
    plan=run(cells--[switch],loaded)
    assert plan.sources[key(b1)].current_a==0.0
    assert plan.supplied_j==0.0 and plan.powers==%{}
    closed=run(cells,Map.put(loaded,Damage.key(switch),Map.put(switch,:closed,true)))
    i=48.0/(2*2*half(20.0)+16*half(@cu))
    assert_in_delta closed.sources[key(b1)].current_a,i,i*1.0e-9
  end

  test "空电池在放电方向按电动势 0 重解：满的一块经空的一块（电阻）放电；两块都空则 0 A、不放电" do
    [_,b1,b2|_]=cells=loop()
    plan=run(cells,Map.new([stored(b1,1.0e6)]))
    i=24.0/loop_r(2,14)
    assert_in_delta plan.sources[key(b1)].current_a,i,i*@rel
    # 空的一块电流照样穿过（从负极进、正极出，记为放电方向），但电动势功率为 0，不扣储能也不充电。
    assert_in_delta plan.sources[key(b2)].current_a,i,i*@rel
    assert plan.sources[key(b2)].stored_j==0.0
    assert_in_delta plan.supplied_j,24.0*i*0.5,24.0*i*0.5*@rel
    empty=run(cells)
    assert empty.sources[key(b1)].current_a==0.0 and empty.supplied_j==0.0
  end

  test "空电池遇到低于自身电动势的外加：电流 0（不按 0 V 导通）；外加超过电动势才充电" do
    # 充电方向：两块满电池（48 V）从上往下驱动右列一块空电池 b3（正极朝下，见反向串联用例）——48 V > 24 V，b3 充电。
    [_,b1,b2|_]=cells=loop(42,42)
    b3=Enum.at(cells,7)
    charging=run(cells,Map.new([stored(b1,5.0e6),stored(b2,5.0e6)]))
    assert charging.sources[key(b3)].current_a < -100.0 and charging.charged_j>0
    # 只剩一块满电池（24 V）对空的 b3（24 V 反向）：净电动势 0，严格无电流、不充电。
    [_,b|_]=single=loop(24,42)
    b3=Enum.at(single,7)
    weak=run(single,Map.new([stored(b,5.0e6)]))
    assert weak.sources[key(b)].current_a==0.0 and weak.sources[key(b3)].current_a==0.0
    assert weak.charged_j==0.0 and weak.supplied_j==0.0
    # 弱电源换成热电石：热端 h 在下（700 K），冷端 c 在上（293 K），开路电动势 0.05 × (699.25 − 293.9) ≈ 20.3 V，
    # 把电流从上面灌进空电池 b 的正极（充电方向）却低于 24 V：同样 0 A——按 0 V 重解会让电流穿过空格却不储能，这里断开。
    [h,t,c]=[macro({0,0,0},24),macro({0,1,0},43),macro({0,2,0},24)]
    ring=[h,t,c,macro({1,2,0},24),macro({2,2,0},24),macro({2,1,0},42),macro({2,0,0},24),macro({1,0,0},24)]
    b=Enum.at(ring,5)
    plan=run(ring,Map.new([hot(h,700.0),hot(t,500.0),hot(c,293.15)]))
    assert_in_delta plan.sources[key(t)].emf_v,0.05*((8000*700+30*500)/8030-(8000*293.15+30*500)/8030),1.0e-9
    assert plan.sources[key(b)].current_a==0.0 and plan.sources[key(t)].current_a==0.0
  end

  test "放电截断：储能耗尽即截断本段，储能恰为 0" do
    [_,b1,b2|_]=cells=loop()
    i=48.0/loop_r(2,14)
    plan=run(cells,Map.new([stored(b1,100.0),stored(b2,1.0e6)]),10.0)
    assert_in_delta plan.duration,100.0/(24.0*i),100.0/(24.0*i)*@rel
    assert plan.sources[key(b1)].stored_j==0.0
    assert_in_delta plan.supplied_j,2*100.0,200*@rel
  end

  test "反向串联：两块同向 48 V 给一块反接电池充电，I = 24/R；充满后多余的充电功率成为该格的热" do
    # 第三块电池放在负载位置 (2,1)：沿回路方向它的正极朝下，被 48 V 反向驱动，净电动势 24 V。
    [_,b1,b2|_]=cells=loop(42,42)
    b3=Enum.at(cells,7)
    capacity=1.0e7
    plan=run(cells,Map.new([stored(b1,5.0e6),stored(b2,5.0e6),stored(b3,capacity-10.0)]),0.5)
    r=3*2*half(20.0)+14*half(@cu)
    i=24.0/r
    assert_in_delta plan.sources[key(b3)].current_a,-i,i*@rel
    # 充电 24·I·0.5 远大于 10 J 余量：只收 10 J，储能恰到容量，余下成为 b3 的热。
    assert plan.sources[key(b3)].stored_j==capacity
    assert_in_delta plan.charged_j,10.0,1.0e-9
    overflow=24.0*i*0.5-10.0
    joule_b3=i*i*2*half(20.0)
    assert_in_delta plan.powers[key(b3)],joule_b3+overflow/0.5,(joule_b3+overflow/0.5)*@rel
    # 账：热 + 光 = 放电 − 充入储能。
    assert_in_delta Enum.sum(Map.values(plan.powers))*0.5+plan.light_j,plan.supplied_j-plan.charged_j,plan.supplied_j*@rel
  end

  describe "热电石（R8-04 增量 3）" do
    # 热铜 H (0,0) — 热电石 T (1,0) — 冷铜 C (2,0) 沿 x 一排。界面温度按 k/半格长加权：g_Cu = 4000/0.5，g_TE = 15/0.5。
    defp ti(t_cu,t_te),do: (8000*t_cu+30*t_te)/8030

    test "开路：电流为 0，开路电动势 = S × (T_i热 − T_i冷)，冷热两端电位差等于它" do
      [h,t,c]=cells=[macro({0,0,0},24),macro({1,0,0},43),macro({2,0,0},24)]
      damage=Map.new([hot(h,800.0),hot(t,550.0),hot(c,300.0)])
      plan=run(cells,damage)
      emf=0.05*(ti(800.0,550.0)-ti(300.0,550.0))
      s=plan.sources[key(t)]
      assert_in_delta s.emf_v,emf,1.0e-9
      assert_in_delta emf,24.90660,1.0e-5
      assert s.current_a==0.0 and s.stored_j==0.0
      assert plan.powers==%{} and plan.thermoelectric_j==0.0
    end

    test "闭合回路：I = ε/R；热电做功 Σε·i = 全部焦耳热 = 佩尔捷吸热，热节点净得 = −光（热电能量从热里来）" do
      # 回路（z = 0）：H (0,2) — T (1,2) — C (2,2)，C 下合金 (2,1)，底行 (2,0)(1,0)(0,0) 铜，(0,1) 铜回到 H；(1,1) 空气。
      [h,t,c|rest]=cells=[macro({0,2,0},24),macro({1,2,0},43),macro({2,2,0},24),macro({2,1,0},40),
        macro({2,0,0},24),macro({1,0,0},24),macro({0,0,0},24),macro({0,1,0},24)]
      damage=Map.new([hot(h,1300.0),hot(t,818.0),hot(c,480.0)])
      plan=run(cells,damage,0.5)
      emf=0.05*(ti(1300.0,818.0)-ti(480.0,818.0))
      # 八条边：热电石两个半格、合金两个半格、铜半格 12 个。
      r=2*half(2.0)+2*half(4.0)+12*half(@cu)
      i=emf/r
      assert_in_delta plan.sources[key(t)].current_a,i,i*1.0e-9
      assert_in_delta plan.sources[key(t)].emf_v,emf,1.0e-9
      assert_in_delta plan.thermoelectric_j,emf*i*0.5,emf*i*0.5*1.0e-9
      assert_in_delta Enum.sum(Map.values(plan.powers))*0.5+plan.light_j,0.0,emf*i*0.5*1.0e-9
      # 佩尔捷：热端结吸热 S·T_i·i（铜 S = 0），冷端结放热；各分给两侧一半。
      assert plan.powers[key(h)]<0 and plan.powers[key(c)]>0
      assert_in_delta plan.powers[key(h)],-0.05*ti(1300.0,818.0)*i/2+2*i*i*half(@cu),1.0e-6
      assert_in_delta plan.powers[key(c)],0.05*ti(480.0,818.0)*i/2+2*i*i*half(@cu),1.0e-6
      assert Enum.all?(rest,&Map.has_key?(plan.powers,key(&1)))
    end
  end

  test "线端点不接蓄能石（它只经 ±Y 面导电）；铜宿主照常" do
    b=macro({0,1,0},42)
    cu=macro({0,0,0},24)
    assert Circuit.conductors([b,cu],catalog(),%{})==[cu]
  end

  test "体积导体邻面保留微面面积，绝缘与空气不进入导体图" do
    catalog=catalog()
    macro=%{micro: {8,0,0},granularity: 0,material: 24,owner: {0,0},incarnation: 1}
    micro=%{micro: {0,0,0},granularity: 2,material: 24,owner: {7,1},incarnation: 7}
    samples=[{macro,2},{micro,1},{nil,1},{%{macro | material: 11},1}]
    contacts=Circuit.solid_contacts(samples,catalog,%{})
    assert contacts[{0,{8,0,0}}]=={macro,2/64}
    assert contacts[{1,{0,0,0}}]=={%{micro | granularity: 1},1/64}
    assert map_size(contacts)==2
    # 一整面（同一相邻宏格 64 点）作为一段累计，与逐点 64 次累加的二进制值相同：1/64 的整数倍都精确可表示。
    whole=Circuit.solid_contacts([{macro,64},{micro,1}],catalog,%{})
    pointwise=Circuit.solid_contacts(List.duplicate({macro,1},64)++[{micro,1}],catalog,%{})
    assert whole===pointwise and elem(whole[{0,{8,0,0}}],1)===1.0
    assert Enum.map(Circuit.solid_faces(macro),&length/1)==List.duplicate(64,6)
    assert Enum.map(Circuit.solid_faces(micro),&length/1)==List.duplicate(1,6)
  end

  test "开关材料的格：闭合时按目录电导率进入导体图与接触，断开或无行时绝缘；小块按 granularity 1 热身份的行" do
    catalog=catalog()
    cell=%{micro: {16,0,0},granularity: 0,material: 41,owner: {0,0},incarnation: 3}
    micro=%{micro: {5,6,7},granularity: 2,material: 41,owner: {9,2},incarnation: 9}
    closed=fn t->%{Damage.key(t)=>Map.put(t,:closed,true)} end
    assert Circuit.conductors([cell,micro],catalog,%{})==[]
    assert Circuit.solid_contacts([{cell,1},{micro,1}],catalog,%{})==%{}
    assert Circuit.conductors([cell],catalog,closed.(cell))==[cell]
    assert Circuit.sigma(catalog,closed.(cell),cell)==58.0e6
    thermal=%{micro | granularity: 1}
    assert Circuit.conductors([micro],catalog,closed.(thermal))==[thermal]
    # 构件行（granularity 2）不是微格的开合真值。
    assert Circuit.conductors([micro],catalog,closed.(micro))==[]
  end

  test "种子：有储能的蓄能石、带温度的热电石；空电池与常温无行的热电石不是种子" do
    b=macro({0,0,0},42); t=macro({1,0,0},43); e=macro({2,0,0},42)
    damage=Map.new([stored(b,1.0),hot(t,300.0),stored(e,0.0)])
    seeds=Circuit.seeds(damage,catalog())
    assert Enum.sort(Enum.map(seeds,& &1.micro))==[b.micro,t.micro]
  end

  describe "电阻发光材料（R8-04）" do
    # 只测试：一条铜微格 — n 个电阻合金微格 — 铜微格的线；两端铜微格分别接在一块 1/8 m 蓄能石微格（3 V）的上下：
    # 下端铜在电池下方，电池上方是一格铜，再由一根铜线（附件）接回线的末端铜。期望按 r = d/(σA) 手算。
    @micro_area 1/64
    defp micro(x,y,material),do: %{micro: {x,y,0},granularity: 1,material: material,owner: {9,0},incarnation: 100+x+10*y}
    defp resistive(n,wire \\ 24,closed \\ nil) do
      # 电池微格 B (0,1)，下 cu_bottom (0,0)、上 cu_top (0,2)；cu_top 右接 n 格合金 (1..n,2)，再接 cu_end (n+1,2)；
      # 一根 1/8 m 铜线（附件）从 cu_end 接回 cu_bottom（两端宿主直接给出）。
      bottom=micro(0,0,24); bat=micro(0,1,42); top=micro(0,2,24)
      chain=[top]++for(x<-1..n,do: micro(x,2,40))++[micro(n+1,2,24)]
      contacts=[{bottom,bat,@micro_area},{bat,top,@micro_area}]++
        for([p,q]<-Enum.chunk_every(chain,2,1,:discard),do: {p,q,@micro_area})
      slot={1,0,{1,3,0}}
      damage=Map.new([stored(bat,1.0e4)])
      damage=if closed==nil,do: damage,else: Map.put(damage,{3,1},Map.put(VoxelRegion.Attachments.identity(slot,{1,wire}),:closed,closed))
      input=Circuit.prepare(%{slot=>{1,wire}},damage,catalog(),0.5,%{"ambient_kelvin"=>@ambient})
      # 断开的开关线不进网络：没有端点，也就没有宿主。
      hosts=case Circuit.points(input) do
        [a,b]->%{a=>[List.last(chain)],b=>[bottom]}
        []->%{}
      end
      plan=Circuit.plan(input,hosts,contacts)
      {plan,chain,bat}
    end
    defp copper_host,do: 0.125/2/(@cu*@section)
    defp copper_alloy,do: (0.125/@cu+0.125/4)/2/@micro_area
    defp chain(n) do
      wire=0.125/(@cu*@section)
      bat=2*(0.125/20/2/@micro_area)
      bat+2*(0.125/@cu/2/@micro_area)+2*copper_host()+wire+2*copper_alloy()+(n-1)*2.0
    end

    test "单格灯丝：接触边按电阻份额分热，灯丝得到自身两条接触边 I²R 的 ≥ 1 − 1e-6，铜几乎为 0" do
      {plan,[cu,fil,_],bat}=resistive(1)
      i=3.0/chain(1)
      assert_in_delta plan.sources[key(bat)].current_a,i,i*1.0e-9
      edge_joule=2*i*i*copper_alloy()
      {_,w,a}=plan.electric[{1,fil.micro}]
      assert w>=(1-1.0e-6)*edge_joule and w<=edge_joule
      assert_in_delta a,i,1.0e-9
      # 灯丝 λ = 0.2：热节点只得 0.8；铜只得接触边里自己那半格的份额，没有光。
      assert_in_delta plan.powers[{1,fil.micro}],0.8*w,1.0e-9
      refute Map.has_key?(plan.electric,{1,cu.micro})
    end

    test "回程线里的开关附件（材料 41）：没有行或断开时线不进网络、严格 0 A；闭合按铜的电导率" do
      for closed<-[nil,false] do
        {plan,_,bat}=resistive(1,41,closed)
        assert plan.sources[key(bat)].current_a==0.0 and plan.supplied_j==0.0
      end
      {plan,_,bat}=resistive(1,41,true)
      assert_in_delta plan.sources[key(bat)].current_a,3.0/chain(1),3.0/chain(1)*1.0e-9
    end

    test "n 格灯丝串联：I = E /(电池 + 2n + 铜)，光 = λ × 灯丝焦耳，热 + 光 = 放电" do
      for n<-[1,2,5] do
        {plan,cells,bat}=resistive(n)
        i=3.0/chain(n)
        assert_in_delta plan.sources[key(bat)].current_a,i,i*1.0e-9
        filament=for c<-cells,c.material==40,do: elem(plan.electric[{1,c.micro}],1)
        assert length(filament)==n
        assert_in_delta plan.light_j,0.2*Enum.sum(filament)*plan.duration,1.0e-9
        assert_in_delta Enum.sum(Map.values(plan.powers))*plan.duration+plan.light_j,plan.supplied_j,1.0e-6
        assert_in_delta plan.supplied_j,3.0*i*plan.duration,1.0e-6
      end
    end
  end
end
