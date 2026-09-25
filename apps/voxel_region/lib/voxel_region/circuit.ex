defmodule VoxelRegion.Circuit do
  @moduledoc """
  全局系统功能：从规范占用重建直流拓扑，生成独立电气观察与按热节点分配的功率。

  R8-04 增量 3 起电路里没有设备：电动势只来自材料格（宏格或微格），导体是导电材料的格、线与面。
  - **蓄能石**（目录 `battery_energy_per_macro_j`、`battery_volts_per_m`）：电动势 = 每米伏数 × 格边长，正极朝 +Y；
    只经 ±Y 面导电（其他面的接触、线端点都不接它）。格心到上下两面各升 E/2，落在它的 ±Y 接触边上。
    储能 `stored_j` 在格的属性行上（宏格行／微格 granularity 1 热行），新放置为空；放电扣、充电加，
    充满后的充电功率成为该格的热。空格若在放电方向，按电动势 0 重解（成为电阻，例如与有电的格串联）；
    重解后若电流反成充电方向（外加电动势低于它自己的电动势），它两端电压介于 0 与 E 之间、电流为 0：
    该格的接触边断开（外加不足以给空格充电，不产生无储能的“充电”电流）。
  - **热电石**（目录 `seebeck_v_per_k` S）：接触边 a→b 的电动势升 ε = −[S_a(T_i − T_a) + S_b(T_b − T_i)]，
    界面温度 T_i 按两侧 k/(半格长) 加权；每个结吸收佩尔捷热 (S_b − S_a)·T_i·i（两侧各一半）。按 KCL，
    全网 Σε·i = Σ佩尔捷，热电做功恰由热节点支付。
  """
  alias VoxelRegion.{Attachments,Climate,Damage,DCNetwork,ThermalGeometry}
  @micro VoxelRegion.Spatial.micro_resolution()
  @length 1.0/@micro

  @doc """
  目标此刻的体积电导率 S/m。开关材料（目录 `circuit_switch`）只在其属性行 `closed` 为真时按目录值导电，
  缺省（没有行或未闭合）断开、绝缘；格用自身行（微格用 granularity 1 热行），附件用整件行。
  """
  def sigma(catalog,damage,target) do
    m=catalog.materials[target.material]
    if Map.get(m,"circuit_switch",false) and not Map.get(Map.get(damage,Damage.key(target),%{}),:closed,false),
      do: 0.0,else: Map.get(m,"electrical_conductivity",0.0)
  end

  @doc "蓄能石：带储能与每米电动势的材料。"
  def battery?(material),do: Map.has_key?(material,"battery_volts_per_m")
  @doc "热电石的塞贝克系数 V/K；其他材料 0。"
  def seebeck(material),do: Map.get(material,"seebeck_v_per_k",0.0)

  @doc """
  电路的种子：有储能的蓄能石格、带温度记录的热电石格（热身份目标）。没有种子时全世界没有电动势，不求解。
  """
  def seeds(damage,catalog) do
    for {_,%{granularity: g}=row}<-damage,g in [0,1],m=catalog.materials[row.material],
        (battery?(m) and Map.get(row,:stored_j,0.0)>0.0) or (seebeck(m) != 0.0 and Map.has_key?(row,:temperature_kelvin)),
        do: Map.take(row,[:micro,:granularity,:incarnation,:owner,:material])
  end

  @doc """
  由目录和附件导体准备网络（线与面各自成边）；不读取 canonical 占用。
  domain（可选）把附件槽映射到其受保护区域持有者：端点按持有者分开，跨持有者边界的导线不在端点处相连；
  nil 时端点为 `{:point, p}`。`environment` 为热环境配置：无温度记录的导体取其宏格所在气候区的环境温度。
  """
  def prepare(slots,damage,catalog,duration,environment,domain \\ nil) do
    started=System.monotonic_time(:microsecond)
    section=catalog.attachments["line_section_m2"]
    {edges,luminous}=Enum.reduce(slots,{[],%{}},fn {slot={kind,axis,p},{id,material}},{edges,luminous}->
      sigma=sigma(catalog,damage,Attachments.identity(slot,{id,material}))
      if sigma>0 do
        key=VoxelRegion.ThermalAttachments.key(slot)
        lum=luminous_fraction(catalog,material)
        heat=[{key,1.0,lum}]
        luminous=if lum>0,do: Map.put(luminous,key,Attachments.identity(slot,{id,material}) |> Map.put(:granularity,4)),else: luminous
        o=domain && domain.(slot)
        edges=if kind==1 do
          [edge(node(p,domain,o),node(offset(p,axis,1),domain,o),@length/(sigma*section),heat)|edges]
        else
          [u,v]=Enum.reject(0..2,&(&1==axis))
          corners=[p,offset(p,u,1),offset(p,v,1),p |> offset(u,1) |> offset(v,1)]
          r=2.0/(sigma*catalog.attachments["face_thickness_m"])
          for {a,b}<-[{0,1},{0,2},{1,3},{2,3}],reduce: edges do
            acc->[edge(node(Enum.at(corners,a),domain,o),node(Enum.at(corners,b),domain,o),r,heat)|acc]
          end
        end
        {edges,luminous}
      else
        {edges,luminous}
      end
    end)
    %{catalog: catalog, damage: damage, environment: environment, edges: edges, luminous: luminous,
      duration: duration, started: started}
  end

  @doc "需要接入实体导体的端点节点（`{:point, p}` 或带持有者的 `{:point, p, holder}`）；保持原边顺序。"
  def points(input), do: input.edges |> Enum.flat_map(&[&1.a,&1.b]) |> Enum.uniq()

  @doc "端点节点周围的八个 canonical 微格采样点。"
  def near_points(point), do: for(x<-[-1,0],y<-[-1,0],z<-[-1,0],do: add(elem(point,1),{x,y,z}))

  @doc "线端点的宿主：按首次命中身份保留此刻导电的真实导体（断开的开关、只经 ±Y 面导电的蓄能石不算），微格使用独立热身份。"
  def conductors(targets,catalog,damage) do
    targets |> Enum.reject(&is_nil/1) |> Enum.map(&thermal_target/1)
      |> Enum.uniq_by(&ThermalGeometry.key/1)
      |> Enum.filter(&(sigma(catalog,damage,&1)>0 and not battery?(catalog.materials[&1.material])))
  end

  @doc """
  体积导体六个面的微格采样，每面一组（宏格每面 8×8 点，都落在同一个相邻宏格里；微格每面 1 点）；
  不依赖热接触缓存或区域划分。
  """
  def solid_faces(target) do
    n=if target.granularity==0,do: @micro,else: 1
    for axis<-0..2,sign<-[-1,1] do
      [u,v]=Enum.reject(0..2,&(&1==axis))
      for a<-0..(n-1),b<-0..(n-1),
        do: target.micro |> offset(axis,if(sign<0,do: -1,else: n)) |> offset(u,a) |> offset(v,b)
    end
  end

  @doc """
  将各面实际采样按此刻导电的导体身份累计接触面积；重复微面保留实际面积贡献。
  采样以 `{目标, 点数}` 成段给出（同一相邻宏格的一整面是一段）；每点面积 1/64 m²，段面积 = 点数 × 1/64，
  与逐点累加的二进制值相同（全是 1/64 的整数倍）。
  """
  def solid_contacts(runs,catalog,damage) do
    Enum.reduce(runs,%{},fn {target,count},contacts ->
      target=target && thermal_target(target)
      if target && sigma(catalog,damage,target)>0 do
        key=ThermalGeometry.key(target)
        Map.update(contacts,key,{target,count*@length*@length},fn {other,area}->{other,area+count*@length*@length} end)
      else
        contacts
      end
    end)
  end

  @doc """
  求解冻结的端点宿主与实占用接触摘要，输出功率、储能与电源观察，不返回世界。

  每条支路的 I²R 按两侧各自的电阻份额分给两侧热节点（接触边 r = r_a + r_b，a 得 r_a/r）；节点所在材料的
  `luminous_fraction` λ 那一份离开热账记为光（`light_j`），其余进热节点。发光节点另给出电功率与通过电流
  （`electric`：热键 → {目标, W, A}；A = 该节点全部支路 |i| 之和的一半）。
  `sources`：本次网络里每个蓄能石／热电石格 → %{target, stored_j, emf_v, current_a}（电流带号：+ 为向外供能）。
  账：`supplied_j` 放电、`charged_j` 充入储能、`thermoelectric_j` 热电做功（= 佩尔捷吸热）、`light_j` 光；
  热节点净得 supplied − charged − light（充满后的溢出也在热里）。
  """
  def plan(input,hosts,contacts) do
    %{catalog: catalog,damage: damage,environment: environment,edges: edges,luminous: luminous,
      duration: duration,started: started}=input
    section=catalog.attachments["line_section_m2"]
    {edges,luminous}=Enum.reduce(points(input),{edges,luminous},fn p,acc ->
      Enum.reduce(Map.fetch!(hosts,p),acc,fn target,{edges,luminous} ->
        key=ThermalGeometry.key(target)
        sigma=catalog.materials[target.material]["electrical_conductivity"]
        lum=luminous_fraction(catalog,target.material)
        {[edge(p,{:solid,key},size(target)/2/(sigma*section),[{key,1.0,lum}])|edges],glowing(luminous,key,target,lum)}
      end)
    end)
    temperature=fn target -> Map.get(Map.get(damage,Damage.key(target),%{}),:temperature_kelvin,
      Climate.air_k(environment,Damage.macro(target))) end
    # owner 保留原遍历和前插次序；纯计算按同一边顺序求解，避免浮点累加漂移。
    {contact_edges,{luminous,cells}}=Enum.flat_map_reduce(contacts,{luminous,%{}},fn {target,other,area},{luminous,cells} ->
      ma=catalog.materials[target.material]; mb=catalog.materials[other.material]
      {axis,side}=side(target,other)
      if (battery?(ma) or battery?(mb)) and axis != 1 do
        {[],{luminous,cells}}
      else
        a=ThermalGeometry.key(target); b=ThermalGeometry.key(other)
        ra=size(target)/ma["electrical_conductivity"]/2/area
        rb=size(other)/mb["electrical_conductivity"]/2/area
        la=luminous_fraction(catalog,target.material); lb=luminous_fraction(catalog,other.material)
        # 蓄能石（正极 +Y）：沿 a→b 方向，a 的格心到界面、界面到 b 的格心各升 side·E/2（对方在 +Y 侧时为正）。
        batteries=for {t,m,k}<-[{target,ma,a},{other,mb,b}],battery?(m),do: {k,side*emf(m,t)/2}
        # 热电石：界面温度按 k/半格长加权；a→b 的电动势升与结上的佩尔捷系数。
        sa=seebeck(ma); sb=seebeck(mb)
        {parts,peltier,interface}=if sa != 0.0 or sb != 0.0 do
          ta=temperature.(target); tb=temperature.(other)
          ga=ma["thermal_conductivity"]/(size(target)/2); gb=mb["thermal_conductivity"]/(size(other)/2)
          ti=(ga*ta+gb*tb)/(ga+gb)
          {[{a,-sa*(ti-ta)},{b,-sb*(tb-ti)}],(sb-sa)*ti,ti}
        else
          {[],0.0,nil}
        end
        cells=cells |> source_cell(a,target,ma) |> source_cell(b,other,mb)
          |> face(a,ma,{axis,side},interface,area) |> face(b,mb,{axis,-side},interface,area)
        e=%{edge({:solid,a},{:solid,b},ra+rb,[{a,ra/(ra+rb),la},{b,rb/(ra+rb),lb}]) |
          te: Enum.reduce(parts,0.0,fn {_,v},t->t+v end),te_parts: parts,peltier: peltier,batteries: batteries,
          sides: [{a,side,axis},{b,-side,axis}]}
        {[e],{luminous |> glowing(a,target,la) |> glowing(b,other,lb),cells}}
      end
    end)
    edges=contact_edges++edges
    stored=Map.new(cells,fn {key,c}->{key,Map.get(Map.get(damage,Damage.key(c.target),%{}),:stored_j,0.0)} end)
    {result,flat}=solve(edges,stored,MapSet.new(),MapSet.new())
    currents=Enum.map(result.currents,fn i->if abs(i)<1.0e-10,do: 0.0,else: i end)
    {heat,light_w,electric,cells,te_w}=Enum.zip(edges,currents) |> Enum.reduce({%{},0.0,%{},cells,0.0},fn {e,i},{heat,light,electric,cells,te_w}->
      watts=i*i*e.r
      {heat,light}=Enum.reduce(e.heat,{heat,light},fn {key,weight,lum},{h,light}->
        {Map.update(h,key,watts*weight*(1.0-lum),&(&1+watts*weight*(1.0-lum))),light+watts*weight*lum}
      end)
      electric=Enum.reduce(e.heat,electric,fn {key,weight,lum},acc->
        if lum>0,do: Map.update(acc,key,{watts*weight,abs(i)},fn {w,a}->{w+watts*weight,a+abs(i)} end),else: acc
      end)
      # 佩尔捷：结上吸收 (S_b − S_a)·T_i·i，两侧热节点各付一半。
      heat=if e.peltier != 0.0 and i != 0.0,
        do: Enum.reduce(e.heat,heat,fn {key,_,_},h->Map.update(h,key,-e.peltier*i/2,&(&1-e.peltier*i/2)) end),else: heat
      cells=Enum.reduce(e.sides,cells,fn {key,side,axis},cells->
        case cells do
          %{^key=>c}->
            # 蓄能石本格的电动势功率（放电为正）；穿过电流按经 +Y 面流出记正。
            power=Enum.reduce(e.batteries,0.0,fn {k,rise},p->if k==key and not MapSet.member?(flat,k),do: p+rise*i,else: p end)
            out=if key==elem(e.a,1),do: i,else: -i
            Map.put(cells,key,%{c | power: c.power+power,through: c.through+abs(i),
              top: if(axis==1 and side==1,do: c.top+out,else: c.top),te: c.te+te_part(e,key,i)})
          _->cells
        end
      end)
      {heat,light,electric,cells,te_w+e.te*i}
    end)
    # 放电中的蓄能石决定本段时长（与原有限电源同一截断口径）。
    done=Enum.reduce(cells,duration,fn {key,c},dt->
      if c.battery and c.power>0 and stored[key]>0,do: min(dt,stored[key]/c.power),else: dt
    end)
    {cells,heat,supplied,charged}=Enum.reduce(cells,{cells,heat,0.0,0.0},fn {key,c},{all,heat,supplied,charged}->
      cond do
        not c.battery -> {all,heat,supplied,charged}
        c.power>0 ->
          left=if done==stored[key]/c.power,do: 0.0,else: max(0.0,stored[key]-c.power*done)
          {Map.put(all,key,%{c | stored: left}),heat,supplied+c.power*done,charged}
        c.power<0 ->
          room=catalog.materials[c.target.material]["battery_energy_per_macro_j"]*Damage.volume(c.target.granularity)-stored[key]
          taken=min(max(room,0.0),-c.power*done)
          overflow=-c.power*done-taken
          # 充满之后的充电功率成为本格的热。
          heat=if overflow>0,do: Map.update(heat,key,overflow/done,&(&1+overflow/done)),else: heat
          {Map.put(all,key,%{c | stored: stored[key]+taken}),heat,supplied,charged+taken}
        true -> {Map.put(all,key,%{c | stored: stored[key]}),heat,supplied,charged}
      end
    end)
    electric=for {key,{w,a}}<-electric,w>0.0,into: %{},do: {key,{Map.fetch!(luminous,key),w,a/2}}
    sources=Map.new(cells,fn {key,c}->{key,source_view(c)} end)
    %{duration: done,powers: Map.reject(heat,fn {_,w}->w==0.0 end),supplied_j: supplied,charged_j: charged,
      thermoelectric_j: te_w*done,light_j: light_w*done,electric: electric,sources: sources,
      nodes: map_size(result.volts),edges: length(edges),elapsed_us: System.monotonic_time(:microsecond)-started}
  end

  # 求解；放电方向上已空的蓄能石按电动势 0 重解；按 0 重解后电流反成充电方向的空格断开（电流 0）。直到状态不再变化；
  # 每格至多经历一次“空 → 电动势 0 → 断开”，迭代有限。返回的电流与原边同序（断开的边为 0）。
  defp solve(edges,stored,flat,blocked) do
    open=fn e->Enum.any?(e.batteries,fn {k,_}->MapSet.member?(blocked,k) end) end
    live=for e<-edges,not open.(e),do: %{e | emf: emf_of(e,flat)}
    result=DCNetwork.solve(live)
    {currents,[]}=Enum.map_reduce(edges,result.currents,fn e,rest->
      if open.(e),do: {0.0,rest},else: {hd(rest),tl(rest)}
    end)
    result=%{result | currents: currents}
    # 按名义电动势计的功率：> 0 放电方向，< 0 充电方向。
    power=Enum.zip(edges,currents) |> Enum.reduce(%{},fn {e,i},p->
      Enum.reduce(e.batteries,p,fn {k,rise},p->Map.update(p,k,rise*i,&(&1+rise*i)) end)
    end)
    empty=for {k,w}<-power,w>0.0,Map.get(stored,k,0.0)<=0.0,not MapSet.member?(flat,k),do: k
    stuck=for {k,w}<-power,w<0.0,MapSet.member?(flat,k),not MapSet.member?(blocked,k),do: k
    if empty==[] and stuck==[],do: {result,flat},
      else: solve(edges,stored,MapSet.union(flat,MapSet.new(empty)),MapSet.union(blocked,MapSet.new(stuck)))
  end

  # 生产约定：支路电流 a→b = (V_a − V_b − emf)/r，所以 emf 是 a→b 电动势升的相反数。
  defp emf_of(e,flat),
    do: -(e.te+Enum.reduce(e.batteries,0.0,fn {k,rise},s->if MapSet.member?(flat,k),do: s,else: s+rise end))

  # 本格在该边上的塞贝克分量（格心到界面）乘电流：a 侧 −S_a(T_i − T_a)，b 侧 −S_b(T_b − T_i)，两者之和即 e.te。
  defp te_part(e,key,i),do: Enum.reduce(e.te_parts,0.0,fn {k,part},w->if k==key,do: w+part*i,else: w end)

  defp source_cell(cells,key,target,material) do
    cond do
      Map.has_key?(cells,key) -> cells
      battery?(material) -> Map.put(cells,key,%{target: target,battery: true,emf: emf(material,target),power: 0.0,
        through: 0.0,top: 0.0,te: 0.0,stored: 0.0,faces: %{}})
      seebeck(material) != 0.0 -> Map.put(cells,key,%{target: target,battery: false,emf: 0.0,power: 0.0,
        through: 0.0,top: 0.0,te: 0.0,stored: 0.0,faces: %{},s: seebeck(material)})
      true -> cells
    end
  end

  # 热电石各面接触的界面温度（按面积加权），用于开路电动势观察 max_轴 |S (T̄_i(−) − T̄_i(+))|。
  defp face(cells,_key,_material,_face,nil,_area),do: cells
  defp face(cells,key,material,face,ti,area) do
    if seebeck(material) != 0.0 do
      update_in(cells[key].faces,&Map.update(&1,face,{ti*area,area},fn {t,a}->{t+ti*area,a+area} end))
    else
      cells
    end
  end

  defp source_view(%{battery: true}=c),
    do: %{target: c.target,stored_j: c.stored,emf_v: c.emf,current_a: c.top}
  defp source_view(c) do
    emf=Enum.reduce(0..2,0.0,fn axis,m->
      case {Map.get(c.faces,{axis,-1}),Map.get(c.faces,{axis,1})} do
        {{tl,al},{th,ah}}->max(m,abs(c.s*(tl/al-th/ah)))
        _->m
      end
    end)
    current=cond do
      c.te>0 -> c.through/2
      c.te<0 -> -c.through/2
      true -> 0.0
    end
    %{target: c.target,stored_j: 0.0,emf_v: emf,current_a: current}
  end

  # 两个互不重叠的盒（宏格或微格）共面接触：返回法向轴与对方所在的一侧（+1 / −1）。
  defp side(a,b) do
    na=round(size(a)*@micro); nb=round(size(b)*@micro)
    Enum.find_value(0..2,fn axis->
      cond do
        elem(a.micro,axis)+na==elem(b.micro,axis) -> {axis,1}
        elem(b.micro,axis)+nb==elem(a.micro,axis) -> {axis,-1}
        true -> nil
      end
    end)
  end

  defp emf(material,target),do: material["battery_volts_per_m"]*size(target)
  defp node(p,nil,_),do: {:point,p}
  defp node(p,_domain,holder),do: {:point,p,holder}
  defp edge(a,b,r,heat),do: %{a: a,b: b,r: r,emf: 0.0,heat: heat,te: 0.0,te_parts: [],peltier: 0.0,batteries: [],sides: []}
  defp luminous_fraction(catalog,material),do: Map.get(catalog.materials[material],"luminous_fraction",0.0)
  defp glowing(luminous,key,target,lum),do: if(lum>0,do: Map.put(luminous,key,target),else: luminous)
  defp thermal_target(%{granularity: 2}=t),do: %{t | granularity: 1}
  defp thermal_target(t),do: t
  defp size(%{granularity: 0}),do: 1.0
  defp size(_),do: @length
  defp offset(p,axis,n),do: put_elem(p,axis,elem(p,axis)+n)
  defp add({x,y,z},{a,b,c}),do: {x+a,y+b,z+c}
end
