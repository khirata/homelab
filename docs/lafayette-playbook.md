# Lafayette 無人運用プレイブック（2026/10〜2027/1）


## 全体像

Lafayette は WiFi Pass をメイン、Visible を予備の回線にして無人で動いている。どちらの回線にもパブリックIPはないので、Lafayette の通信はすべて外向き。

**構成の要約**

- Lafayette：UCG Fiber（WAN2＝Beryl → xfinitywifi〔WiFi Pass〕、WAN1＝Pixel 6a → Belkin〔Visible〕）。Pi（laf1〜3、lafk1〜3、lafz1）は cloudflared で Cloudflare に外向き接続、laf2（本番）・laf3（予備）は Tailscale のサブネットルーター
- 坂本：UDM-SE（Aterm の MAP-E のポート転送で着信可）。sak1 が踏み台（Aterm 側にいて、UDM-SE の LAN には直接いない）。sak2 は UDM-SE の LAN に有線でつながる Tailscale のサブネットルーター
- 拠点間：両方向とも Tailscale（坂本 → Lafayette は laf2・laf3、Lafayette → 坂本は sak2 を経由）。UCG の WireGuard クライアント（wgclt1）も Lafayette → 坂本の経路として残っている
- 日本からの入口：Cloudflare（SSH・Web）、Tailscale（Mac）、sak.hirata.dev、unifi.ui.com

Pi とカメラは cloudflared で Cloudflare に、UCG は UniFi のクラウドと坂本の WireGuard に、それぞれ Lafayette から接続している。坂本は Aterm のポート転送で着信できる。

## 6a（Visible の予備回線）と MacroDroid

6a は再起動しても人の手なしで約3〜4分でテザリングまで戻り、止まったときは Webhook で日本から切り替えられる。停電などで給電が10秒以上切れたときは、電源が戻るとマクロ4が自動でテザリングをオンに戻す。

### 構成

- Pixel 6a（Visible）→ Belkin USB-C to Ethernet + Charge アダプター → UCG の WAN（予備）
- 接続方式はイーサネットテザリング。RJ45 の抜き差しは自動で復帰する。USB-C の抜き差しはテザリングが切れたまま戻らない
- 充電は Belkin のパススルー経由。充電の上限は 80%

### マクロ1：テザリングを戻す（トリガー2つ）

| 項目 | 設定 |
| --- | --- |
| トリガー | Device Boot（起動時）と Webhook（識別子 tether-toggle）。Webhook の URL は Chrome のブックマークに保存 |
| アクション | Wait 60秒 → Screen On → Launch Activity（Settings$TetherSettingsActivity）→ Wait 3秒 → UI Interaction の Click（座標指定）→ Wait 3秒 → Home screen → Screen Off |
| 動き | 「Ethernet tethering」のスイッチを1回押す。呼ぶたびにオンとオフが入れ替わる |
| 起動時の所要時間 | 再起動から約3〜4分でテザリングが戻る |
| Webhook の所要時間 | 呼んでから約60〜70秒で切り替わる（最初の Wait 60秒のため） |

- クリックは座標で指定している。文字の指定では反応しない（文字の部品ではなく行がタップを受け取るため）
- 座標がずれないよう、Auto-rotate screen はオフ
- 起動直後はテザリングが必ずオフなので、起動時のトリガーで誤ってオフにすることはない。6a の上流が変わると（Wi-Fi につながる・外れるなど）、テザリングが止まることがある

### マクロ2：状態を Loki に送る

| 項目 | 設定 |
| --- | --- |
| トリガー | Regular Interval（5分ごと）、Power Disconnected、Power Connected（給電が変わった瞬間にも1行送る） |
| power の判定 | 電源なし → discharging、電源あり・100% → full、電源あり・79% 超 → not_charging、それ以外 → charging |
| 送り先 | POST https://push-visible.hirata.dev/loki/api/v1/push |
| ヘッダー | Content-Type: application/json、CF-Access-Client-Id、CF-Access-Client-Secret（Header Params に入れる） |
| 本文 | 時刻は System time (ms) の後ろに 000000 を付けてナノ秒。1行は battery= temp= power= |

- Local の変数は {lv=pw} と書く（{v=...} は Global 用）
- 送れなかった分の再送はない。Lafayette や laf3 が止まっている間の記録は欠ける

給電の変化のトリガーは記録を送るだけで、テザリングのスイッチには触らない。USB の接続が一瞬切れても、必ず power=discharging の行が残る。

### マクロ3：6a を再起動する

| 項目 | 設定 |
| --- | --- |
| トリガー | Webhook（再起動用の識別子）。URL は Chrome のブックマークに保存 |
| アクション | Android Shortcuts の Power Options で電源メニューを開く → Wait → UI Interaction で「Restart」をタップ |
| 動き | 6a が再起動し、起動時のマクロ（マクロ1）でテザリングが必ずオンに戻る。再起動の間に Ethernet のリンクが一度切れるので、UCG も新しいアドレスを取り直す |
| 所要時間の目安 | 呼んでから約4〜5分で WAN1 が戻る（再起動と、マクロ1の Wait 60秒を含む） |

- テザリングがオンかオフか分からないときに使う。テザリングの切り替えの Webhook と違い、今の状態に関係なく同じ結果になる
- Device Actions の Reboot / Power Off は root が必要なので使えない

### マクロ4：電源が戻ったらテザリングをオンにする

| 項目 | 設定 |
| --- | --- |
| 記録用のマクロ | Power Disconnected → グローバル変数 lost_at に System time を入れる |
| 本体のマクロ | Power Connected → elapsed ＝ System time − lost_at → Wait 60秒 → If（lost_at が 0 より大きい AND elapsed が 10 より大きい）→ Macro Run でマクロ1を実行（Ignore Constraints）→ lost_at ＝ 0 |
| 動き | 給電が10秒以上切れていたときだけ、テザリングのスイッチを1回押す。停電でテザリングは必ずオフになっているので、確実にオンに戻る。一瞬の給電の揺れでは動かない |

### 端末の設定

- 画面ロックは None（再起動後にマクロを動かすため）。個人のアカウントは外し、MacroDroid Pro のライセンス用に専用の Google アカウントだけを入れている（外さないこと）
- 自動システムアップデート、Play ストアの自動更新はオフ。SIM の PIN ロックはオフ
- Wi-Fi、Bluetooth、位置情報のスキャンはオフ。バッテリーセーバーはスケジュールなし
- ユーザー補助は MacroDroid と MacroDroid UI Interaction の両方がオン
- MacroDroid は Pro

### 性能の目安

- 途切れはほとんどなく、平均ロスは 0.2% 程度
- 夜間は遅延約 100 ms、速度は上下とも約 6.7 Mbps
- 昼間（10〜16時）は遅延 127〜167 ms、下りは 0.5〜2 Mbps まで落ちる
- 経路の MTU の上限は 1440〜1459 バイト

## WiFi Pass（Beryl）と UCG の設定

メインの回線は、近所の xfinitywifi を Beryl で受けて UCG の WAN に入れたもの。どちらの WAN にもパブリックIPはないので、外との接続はすべて Lafayette から張りに行く形になっている。

### WAN の優先順位

| 順位 | WAN | 経路 | 備考 |
| --- | --- | --- | --- |
| 1（プライマリ） | WAN2：WiFi Pass | Beryl → xfinitywifi | 遅延 約18 ms、下り 約97 Mbps、上り 約7 Mbps（5MB の計測） |
| 2（セカンダリ） | WAN1：Visible | 6a → Belkin | Smart Queues あり（下り 2 Mbps。6a 単体の速度は約 1.7 Mbps。Visible が速く出るようになったら上限を上げる）。家全体が Visible のときは遅延 300 ms 前後、下りは非常に遅いが、SSH・Tailscale・Protect は使える |

### UCG のポート

| ポート | つながっているもの |
| --- | --- |
| 1 | WAN2（プライマリ）：Xfinity WiFi Pass（Beryl） |
| 2 | GS308EPP |
| 3 | RT-AX86U |
| 4 | USW Flex 2.5G |
| 5 | WAN1（セカンダリ）：Visible（6a → Belkin） |

### Beryl の設定

- リピーターの接続先は SSID の xfinitywifi。Lock BSSID はオフ（近所の AP が消えたら別の AP に移れるように）
- MAC Mode は Random だが Auto Update MAC がオフなので、MAC は AE:05:2B:61:0E:3C に固定。「Random」のリンクは押さない（押すと MAC が変わり、再認証が必要になる）
- Auto-Enable Login Mode for Public Hotspots はオフ
- 管理画面は 192.168.8.1（Lafayette の LAN から UCG 経由で届く）

Beryl の nginx のヘッダー用のバッファは「4 8k」（Cloudflare 経由で管理画面を開くのに必要）。nginx.conf は /etc/sysupgrade.conf に載せてあるので、バックアップと、設定を残すファームウェアの更新で引き継がれる。更新したら beryl.hirata.dev が開けるか確かめ、400 のエラーなら cloudflared-deployment の README の手順で入れ直す。

### WiFi Pass の認証と更新

- 30日ごとに自動で更新される
- 認証はホットスポットの側で、Beryl の WAN 側の MAC アドレス（AE:05:2B:61:0E:3C）に対して記録される。Beryl の後ろの機器は、すべてこの認証で外に出る
- 未認証の MAC から HTTP のページを開くと、ホットスポットがログイン画面（connected.xfinity.com）に転送する。Beryl の管理画面からは転送されない（GL.iNet のログイン補助の機能はオフ）
- MAC が変わると、再認証が必要になる。Beryl の MAC の設定は変えない

#### 再認証の手順（日本から）

再認証が必要かどうかは、`ssh beryl-cf` で Beryl に入り、次で判断する：

```
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' http://connectivitycheck.gstatic.com/generate_204
```

- `204` だけ：ログイン済み。WiFi Pass の問題ではない
- `302 https://cp-app.wifi.connected.xfinity.com/welcome?h=...`：ログイン画面に止められている。下の手順で再認証する
- `000`（名前解決もできない）：ログイン画面ではなく、AP との接続の問題。症状別の対応の手順で、リピーターを接続し直す

1. Beryl を出口にした SOCKS プロキシを張る：`ssh -N -D 1080 beryl-cf`（Beryl 用のトンネル。トンネルが使えないときは `ssh -J laf3-cf -N -D 1080 root@192.168.8.1`）
2. Mac のブラウザの SOCKS プロキシを localhost:1080 にする
3. Chrome の**シークレットウィンドウ**で http://neverssl.com を開く。cp-app.wifi.connected.xfinity.com のログイン画面に転送されるので、**WiFi Pass のアカウント**でログインする（通常のウィンドウだと、Chrome に残っている別の Xfinity のアカウントが自動で使われることがある）
4. プロキシの設定を元に戻し、UniFi で WAN2 が戻ったことを確認する

ログインのあと、Beryl で上の `curl` が `204` だけを返すことを確かめる。1〜2分で UCG が WAN2 に戻る。

### 近所の xfinitywifi（2階のルーター横）

| BSSID | 平均の電波 | 見えた割合 |
| --- | --- | --- |
| 82:da:c2:f4:d8:d8 | -40 dBm | 98% |
| 4e:d7:4a:a0:fd:24 | -63 dBm | 83% |

- BSSID が切り替わっても途切れは数秒で、外から見える IP も変わらず、再認証は不要

### UCG の VPN

| 項目 | 設定 |
| --- | --- |
| VPN クライアント | Sakamoto WireGuard（wgclt1）→ sak.hirata.dev:52400、トンネルのアドレス 192.168.1.6 |
| MTU | 1360（MSS は Auto） |
| 経路の設定 | TV（XBR-65930D）ともう1台を送信元に、宛先 Any でこのクライアントへ |
| Site Magic（SD-WAN） | なし（両拠点ともゲートウェイの WAN がプライベート IP のため使えない） |
| Lafayette の WireGuard サーバー | 着信できないので使えない |

### MTU が 1360 の理由

xfinitywifi と Visible のどちらの経路も、分割なしに送れる上限が 1440〜1459 バイトしかない。WireGuard の既定の MTU（1420）に包みの約60バイトが乗ると上限を超え、大きなパケットが落ちる。そのため、**両側の MTU を 1360** にしている：Lafayette の UCG の VPN クライアント（wgclt1）と、坂本の UDM-SE の WireGuard サーバー。片側だけだと、TLS の途中で止まる、TV で Netflix Japan に接続できない、などの症状になる。坂本の WireGuard に直接つなぐ端末（Mac など）も、トンネルの MTU を 1360 にする。

## 日本からの入り方

Lafayette には着信できないので、Cloudflare か UniFi のクラウドを経由して入る。laf.hirata.dev への直接の SSH（laf2 の踏み台）は使えない。

| 経路 | 使い方 | 前提・弱点 |
| --- | --- | --- |
| Cloudflare SSH | `ssh <ノード>-cf`（laf1・laf2・laf3・lafz1・lafk1・lafk2・lafk3）。初回はブラウザで Access の認証 | 各ノードのホスト用トンネル（レプリカ1台）。そのノードの cloudflared が止まると入れない |
| IP-KVM | lafkvm.hirata.dev | 共有トンネル homelab-kvm（laf1〜laf3 の3台で冗長）。SSH が効かないノードの画面を見る |
| Web の画面 | grafana.hirata.dev、infisical.hirata.dev、wazuh.hirata.dev | Cloudflare Access で保護 |
| UniFi Site Manager | unifi.ui.com | UCG の管理、WAN の状態 |
| 坂本の踏み台 | `ssh sak.hirata.dev`（sak1） | 坂本は Aterm の MAP-E のポート転送で着信できる |
| Beryl | 管理画面は https://beryl.hirata.dev、SSH は ssh beryl-cf。これらが使えないとき（Visible に切り替わった直後など）は、Tailscale で ssh -N -L 8443:192.168.8.1:443 khirata@10.77.3.202（laf2。だめなら 10.77.3.203 の laf3）をつなぎ、https://localhost:8443 を開く。再認証用のプロキシは ssh -N -D 1080 beryl-cf | 共有トンネル homelab-beryl（laf1〜laf3 の3台で冗長）。Beryl の xfinitywifi 側が切れていても、Beryl が動いていれば入れる |
| Tailscale | tailnet に参加した機器（laf2、laf3、sak1、sak2、Mac の khmba25）から、Lafayette の LAN（10.77.1〜3.x）と坂本の LAN（10.77.11〜13.x）に直接届く。日本からは ssh -J sak.hirata.dev khirata@10.77.3.x でも入れる | サブネットルーターは Lafayette が laf2（本番）と laf3（予備）、坂本が sak2。Lafayette 側は両方が止まると使えない。Cloudflare にも UniFi にも頼らない独立した経路 |

WAN が切り替わると、Cloudflare との接続は一度切れ、各 cloudflared がつなぎ直す。レプリカが3台ある共有トンネル（KVM、Beryl）はすぐに戻るが、レプリカ1台のホスト用のトンネルは戻るまでに数分かかることがある。待てないときは、戻っている別のホストを足場にして LAN の中から入る（例：`ssh -J laf2-cf laf3`）。

### 拠点間の通信

- Lafayette → 坂本：Tailscale で届く。sak2 が坂本のサブネットルーター（10.77.11〜13.0/24 を広告）で、laf2・laf3 が `--accept-routes` で受け入れている。予備はなく、sak2 が止まると Tailscale では届かない。UCG の VPN クライアント（wgclt1）も残っている
- 坂本 → Lafayette：Tailscale で届く。laf2 が本番、laf3 が予備のサブネットルーター（10.77.1〜3.0/24 を両方が広告）で、laf2 が止まると自動で laf3 に切り替わる。切り替わったあと、laf2 が戻っても自動では戻らない（戻すなら laf3 で `sudo systemctl restart tailscaled`）。今どちらが本番かは、sak1 で `traceroute -n 10.77.3.1` の1つ目の中継点で分かる。日本からは `ssh -J sak.hirata.dev khirata@10.77.3.x` で入る。中継（DERP、サンフランシスコ）経由で、遅延は約 130 ms
- sak1 も `--accept-routes` で、坂本の LAN（UDM-SE の内側）へは sak2 経由で届く。sak1 は Aterm 側にいるので、これが sak1 から UDM-SE の内側に届く唯一の経路。坂本の LAN に直接つながる Linux の機器で `--accept-routes` を有効にするときは、その LAN の範囲を main の経路表で引く ip rule が必要（自分の LAN 宛ての通信まで tailnet に送られるため）
- 経路を受け入れる設定は、遠隔の機器では保険を掛けてから変える：`sudo systemd-run --on-active=10m --unit=ts-failsafe /usr/bin/tailscale set --accept-routes=false` → `sudo tailscale set --accept-routes=true` → 確認できたら `sudo systemctl stop ts-failsafe.timer`

### 注意

- Webhook（6a）は、6a のテザリングを通らない経路から呼ぶ。日本からは問題ない。Lafayette の LAN から呼ぶと、Visible に切り替わっている間は、切り替えたテザリングの上から呼ぶことになる

### kh5950x を米国の IP のブラウザとして使う

米国の IP からしか使えないサイト用（NordVPN が使えないとき）。出口は UCG の通常の経路（WiFi Pass なら Comcast、Visible なら Verizon）。

1. 起動する：`ssh lafz1-cf` で入り、`sudo etherwake -i eth0 F0:2F:74:D9:06:98`
2. 1〜2分待ち、unifi.ui.com のクライアントの一覧で kh5950x の IP を確認する（IP は固定していない）
3. 転送をつなぐ：`ssh -N -L 13389:<kh5950x の IP>:3389 laf2-cf`
4. Mac の Windows App で `localhost:13389` に接続する
5. 使い終わったら Windows をシャットダウンする

## 監視と通知

6a の状態は Grafana で見られる。ただし Grafana も通知先も Lafayette にあるので、Lafayette の回線ごと止まった場合は何も届かない。

### Grafana（grafana.hirata.dev）

- Explore で `{job="pixel6a"}` を検索すると、5分ごとの battery・temp・power が見える
- 正常な状態：battery=80、power=not_charging、温度 27〜34℃
- power が4つの値（charging・discharging・full・not_charging）以外の行は無視する
- 1本の線で見たいときは、クエリ全体を `max(...)` で囲む

### アラート

日本から手を打てるものだけに絞る（未作成）。

| アラート | 条件 | 意味 |
| --- | --- | --- |
| 6a が沈黙 | 20分以上ログが届かない | テザリングか 6a の停止。対応は次のセクション |
| 給電が途切れた | power=discharging が1回でも出た | USB の接続か給電が途切れた。テザリングが切れている可能性がある |

電池残量と温度は、アラートにせずダッシュボードだけで見る。

### そのほかに見る場所

- UniFi（Ubiquiti のクラウド）：WAN の切断と切り替えを通知してくる（メールのラベルは UCG-Fiber）。WAN が切れた状態の UCG からは何も送れないので、この通知はクラウドの側から来る
- ntfy：OS が生きていれば、サービスが落ちたことを homelab の仕組みで通知してくる
- 独自の死活監視は置かない
- laf3 の計測：ping（毎分）、近所の xfinitywifi のスキャン（10分ごと）、外から見た回線の名前（毎時。Comcast なら WiFi Pass、Verizon なら Visible）、速度（6時間ごと）を記録している。ssh laf3-cf tail -24 /var/log/visible-probe/isp.csv で直近1日の回線が分かる。`ssh laf3-cf sudo visible-probe report` と `ssh laf3-cf sudo xfinitywifi-scan report` で、途切れの時刻や、82:da・4e:d7 が見えているかが分かる

## 症状別の対応

最初に UniFi Site Manager で UCG が見えるかを確かめる。見えなければ Lafayette は全断で、日本から打てる手はない。見えれば、下の表で症状に当てはまる行を探す。

| 症状 | 確かめること | 対応 |
| --- | --- | --- |
| UniFi で UCG が見えない | Grafana の 6a の記録も止まっているか | 停電か UCG の停止。復電すれば UCG・Pi・Beryl は自動で起動する。6a のテザリングは停電で必ず切れるが、復電するとマクロ4が自動でオンに戻す。WAN1 が戻らなければ Webhook を1回呼び、それでもだめなら UCG の eth4 を上げ直す |
| メインの WAN（WiFi Pass）が落ち、Visible に切り替わった | beryl.hirata.dev で Beryl の管理画面を開く（Beryl 用のトンネル） | 管理画面でリピーターが未認証なら、「WiFi Pass の認証と更新」の手順（beryl-cf の SOCKS プロキシ）で再認証する。Beryl が固まっていれば、ssh beryl-cf で reboot（入れなければ、SwitchBot のプラグで Beryl の電源を入れ直す）。近所の AP が消えると、Beryl は「接続中」のままインターネットに出られなくなることがある。そのときは beryl.hirata.dev（開けなければ Tailscale 経由の https://localhost:8443）のリピーターの画面で xfinitywifi に接続し直すと、見えている AP（4e:d7 など）を選び直して戻る（再認証は不要）。どの AP が見えているかは ssh laf3-cf sudo xfinitywifi-scan report で分かる |
| 予備の WAN（Visible）が落ちた。Grafana の 6a の記録は届いている | 6a 自体は生きている。テザリングだけ止まっている | UCG に SSH で入り、ip neigh show dev eth4 で 6a（ゲートウェイ）が INCOMPLETE なら、テザリングが止まっている。Webhook を1回呼び、2分待つ。WAN1 が戻らなければ、ip link set eth4 down && sleep 3 && ip link set eth4 up で UCG にアドレスを取り直させる（テザリングは始め直すたびにアドレスの範囲が変わるが、リンクが切れないと UCG は古いアドレスを持ち続ける）。呼ぶたびにオンとオフが入れ替わるので、連続で呼ばない |
| Grafana の 6a の記録が20分以上届かない。Lafayette 全体は生きている | UniFi で予備の WAN の状態 | 上と同じく Webhook を1回。戻らなければ 6a 自体が止まっている（電池切れ、固まった）。帰国まで予備なしで WiFi Pass だけで運用する |
| power=discharging が続く | UCG や Pi も同時に落ちているか | 同時に落ちていれば部屋の停電なので、復電を待つ。6a だけなら充電器か Belkin の異常。電池の残量から持ち時間を見積もる以外に手はない |
| laf2・laf3 が応答しない | Cloudflare SSH、IP-KVM で画面を確認 | SwitchBot のアプリで、そのプラグの電源を切って入れ直す |
| laf1・lafk1〜3・IP-KVM が応答しない | IP-KVM で画面を確認 | GS308EPP の管理画面で、その機器のポートの PoE を入れ直す（電源の遠隔操作を参照） |
| 坂本経由のサイトが開かない（TV など） | DNS は引けるのに、ページが途中で止まる | MTU の問題。UCG の VPN クライアントの MTU が 1360 のままか確認 |
| Webhook が「Not found」を返す | URL が正しいか | MacroDroid を入れ直すと URL が変わる。日本からは直せない |

### discharging の記録を見つけたとき

Loki の記録ではテザリングの状態は分からない。discharging は「USB の接続か給電が途切れた」という合図で、テザリングが止まったかどうかは UniFi で確かめる。

1. Grafana で、power=discharging の行がいつ出たかを見る（短時間でも1行残る）
2. UniFi で、予備の WAN（Visible）が落ちていないか確認する。これがテザリングの状態の確実な判断材料
3. 落ちていれば、Webhook を1回呼ぶ（下の手順）
4. power が not_charging に戻らず discharging が続く場合は、給電そのものが止まっている。電池の残量から持ち時間を見積もる

### Webhook の呼び方

テザリングの状態が分からないとき（スイッチはオンのはずなのに通らないなど）は、先に**再起動の Webhook** を1回呼び、5分待って UniFi で WAN1 が戻ったか確認する。戻らないとき、または停電のあとのようにテザリングが確実にオフのときは、下のテザリングの切り替えの手順を使う。

1. UniFi で、予備の WAN（Visible）が落ちていることを確かめる
2. 日本の端末から `curl -s '<Chrome のブックマークの URL>'` を1回実行する。「OK」が返れば受け付けられている
3. 2分待ってから、UniFi で予備の WAN が戻ったか確認する
4. 戻らなければ、UCG で ip link set eth4 down && sleep 3 && ip link set eth4 up を実行し、さらに2分待つ。それでも戻らなければ、2分以上あけてもう1回呼ぶ（1回目でオフにしてしまった場合、2回目でオンに戻る）。そのあとも eth4 の上げ直しをもう一度行う。2回呼んでも戻らなければ、それ以上は呼ばない

## 電源の遠隔操作

SwitchBot のプラグと PoE で機器の電源を入れ直せるが、どちらも UCG が生きていて、どれかの WAN が使えるときしか日本から操作できない。

| 機器 | 方法 |
| --- | --- |
| laf2、laf3 | SwitchBot Plug Mini でリスタートが可能 |
| laf1、lafk1〜lafk3、IP-KVM | GS308EPP の PoE でリスタートが可能（下の表と手順） |
| Beryl | SwitchBot Plug Mini でリスタートが可能 |
| 6a | MacroDroid のマクロ3（Webhook）でリスタートが可能 |
| UCG | 手段なし（UCG が固まるとプラグにも届かない）。GS308EPP 自体も同じく手段なし |
| カメラ（G6 Instant） | USB 給電なので、電源の入れ直しの手段はない。固まったときは UniFi Protect から再起動する（ソフトウェアの再起動） |
| kh5950x（Windows） | lafz1 から Wake-on-LAN で起動できる。ssh lafz1-cf で入り、sudo etherwake -i eth0 F0:2F:74:D9:06:98（または wakeonlan -i 192.168.11.255 F0:2F:74:D9:06:98）。lafz1 の USB の Ethernet（eth0、192.168.11.2/24 固定）と kh5950x はケーブルで直結 |

### GS308EPP のポート

| ポート | つながっているもの | 入れ直してよいか |
| --- | --- | --- |
| 1 | lafkvm（GL-RM4PE、IP-KVM） | 可。KVM 自体が再起動する |
| 2 | laf2 | しない（SwitchBot で給電） |
| 3 | laf3 | しない（SwitchBot で給電） |
| 4 | UCG Fiber へのアップリンク | 絶対にしない |
| 5 | laf1 | 可 |
| 6 | lafk3 | 可 |
| 7 | lafk2 | 可 |
| 8 | lafk1 | 可 |

### PoE の入れ直しの手順（GS308EPP の管理画面）

1. SwitchBot で給電している laf2 か laf3 を足場にして、スイッチの管理画面を手元に転送する：`ssh -N -L 8081:10.77.3.100:80 laf3-cf`（laf3 が使えなければ laf2-cf）
2. Mac のブラウザで http://localhost:8081 を開き、パスワード管理のパスワードでログインする
3. PoE の画面で、対象のポートの電源を入れ直す
4. 終わったら Logout を押す（このスイッチは同時に1つのログインしか受け付けない）

- 各プラグは、停電から戻ったときの状態を「オン」（または直前の状態）にしておく
- 停電から戻ったとき、UCG・Pi・Beryl は自動で起動する。6a は電池で動き続けるが、充電器の電源が切れるとテザリングは必ずオフになり、電源が戻るとマクロ4が自動でオンに戻す（戻らなければ Webhook を1回呼ぶ）

## 秘密情報と重要な値の置き場所

この文書には値そのものは書かない。どこにあるかだけを記す。

| もの | 置き場所 |
| --- | --- |
| 6a の Webhook の URL（https://trigger.macrodroid.com/<端末ID>/tether-toggle） | Chrome のブックマーク（テザリングの切り替え用と、再起動用の2つ）。知っている人は誰でも操作できる。MacroDroid を入れ直すと変わる |
| push-visible.hirata.dev のサービストークン | `make tf-output-push HOST=push-visible.hirata.dev`（cloudflared-deployment） |
| Cloudflare Tunnel のトークン | Infisical（Terraform が書き込む） |
| 6a 専用の Google アカウント | パスワード管理。MacroDroid Pro の購入記録が紐づく |
| WiFi Pass のアカウント | パスワード管理。Xfinity の契約者 ID とは別のアカウント |
| Beryl の管理画面のパスワード | パスワード管理 |
| GS308EPP の管理画面のパスワード | パスワード管理 |
| UCG の設定のバックアップ | Cryptomator の backups/unifi |
| Beryl の設定のバックアップ | Cryptomator の backups/Beryl（nginx.conf を含む）。取り直しは ssh beryl-cf 'sysupgrade -b /tmp/beryl-backup.tar.gz && cat /tmp/beryl-backup.tar.gz' > beryl-backup-日付.tar.gz |
| Cloudflare の DNS のエクスポート、MacroDroid のマクロのバックアップ | Cryptomator の SecureStore/backups |

## laf2 の NordVPN

止めてある（nordvpnd.service と nordvpnd.socket は disabled、nordvpnd-killswitch.service は mask、毎朝の `nordvpn -d` の cron はコメントアウト）。使うときは次で戻す：

```
sudo systemctl unmask nordvpnd-killswitch.service
sudo systemctl enable --now nordvpnd.socket nordvpnd.service
```

NordVPN に接続すると laf2 の通信は VPN を通り、Firewall の機能も働くので、Tailscale のサブネットルーターや cloudflared への影響を確かめてから使う。

## 帰国後（1月）に戻すこと

- [ ] 新しい固定回線が使えるようになってから、laf2 の DDNS の cron を再開する（コメントに書いた再開条件を確認）
- [ ] Xfinity のモデム、Site Magic、Lafayette の WireGuard サーバーの扱いを、新しい回線に合わせて見直す
- [ ] 6a を回線専用機のまま使い続けるか決める（画面ロックなし、専用のアカウントだけ）
- [ ] laf3 の計測（visible-probe と xfinitywifi-scan）の記録を Mac に保存してから、cron・スクリプト・記録を消し、使っていなければ wlan0 を下ろす（チェックリストの N14）
