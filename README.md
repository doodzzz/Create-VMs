<h1>Create-VMs (From CSV, Cluster-Only, DS Cluster, Pre-GuestOS)</h1>

<p>
Create vSphere VMs from a CSV using <strong>cluster-only placement</strong>. The script clones from templates, builds folder paths, wires networks (VSS/VDS/NSX), chooses storage (Datastore <em>or</em> DatastoreCluster), expands the primary disk, sets CPU/RAM, sets <strong>Guest OS type before power-on</strong>, and (optionally) powers on.
</p>

<p><strong>Script file:</strong> <code>Create-VMs-v0dot5.ps1</code></p>

<hr />

<h2>Features</h2>
<ul>
  <li><strong>Cluster-only placement</strong> (uses the cluster’s root <em>Resources</em> pool)</li>
  <li><strong>Template clone</strong> with minimal params (avoids PowerCLI parameter-set clashes)</li>
  <li><strong>Storage selection</strong>
    <ul>
      <li>Prefer <code>DatastoreCluster</code> (Storage DRS) when provided</li>
      <li>Fall back to a single <code>Datastore</code></li>
    </ul>
  </li>
  <li><strong>Folder path creation</strong> (nested) + move via <code>-InventoryLocation</code></li>
  <li><strong>Networking</strong>
    <ul>
      <li>Detects <strong>VSS</strong>, <strong>VDS</strong>, or <strong>NSX</strong> (by dvPortgroup backing)</li>
      <li>Optional <code>NsxSegmentId</code> for exact NSX segment targeting</li>
      <li>VSS wired <em>pre-power-on</em>; VDS/NSX wired <em>post-power-on</em></li>
    </ul>
  </li>
  <li><strong>Hardware &amp; OS</strong>
    <ul>
      <li>CPU/RAM set <em>pre-power-on</em></li>
      <li>Primary disk <strong>expands</strong> (never shrinks) to requested <code>DiskGB</code></li>
      <li><strong>Guest OS type</strong> set <em>pre-power-on</em></li>
    </ul>
  </li>
  <li><strong>Idempotent</strong>: skips VMs that already exist</li>
  <li>Supports <code>-WhatIf</code> and <code>-Verbose</code></li>
</ul>

<hr />

<h2>Requirements</h2>
<ul>
  <li>Windows PowerShell 5.1 or PowerShell 7+</li>
  <li>VMware PowerCLI (<code>Install-Module VMware.PowerCLI</code>)</li>
  <li>vCenter permissions to read inventory, clone from templates, modify VM hardware, move VMs, power on/off, and attach portgroups (VSS/VDS/NSX)</li>
</ul>

<hr />

<h2>Installation</h2>
<pre><code class="language-powershell"># PowerCLI
Install-Module VMware.PowerCLI

# (Optional) Trust invalid vCenter certs without prompts
Set-PowerCLIConfiguration -InvalidCertificateAction Warn -Confirm:$false
</code></pre>

<p>Place <code>Create-VMs-v0dot5.ps1</code> anywhere in your repo and commit it alongside your CSV.</p>

<hr />

<h2>CSV Schema</h2>

<h3>Required columns</h3>
<table>
  <thead>
    <tr>
      <th>Column</th>
      <th>Example</th>
      <th>Notes</th>
    </tr>
  </thead>
  <tbody>
    <tr><td><code>Datacenter</code></td><td><code>brm-m01-datacenter</code></td><td>Exact DC name</td></tr>
    <tr><td><code>ClusterName</code></td><td><code>brm-m01-cluster-001</code></td><td>Exact cluster name; script uses its <em>Resources</em> pool</td></tr>
    <tr><td><code>Folder</code></td><td><code>Prod/App/Frontend</code></td><td>Nested path under DC’s <strong>VMs</strong> folder; auto-created</td></tr>
    <tr><td><code>VMName</code></td><td><code>SPVM01</code></td><td>Must be unique</td></tr>
    <tr><td><code>Template</code></td><td><code>WIN2019-TPL</code></td><td>Source template name</td></tr>
    <tr><td><code>Network</code></td><td><code>NSXALB</code></td><td>Portgroup name (VSS/VDS/NSX)</td></tr>
    <tr><td><code>vCPU</code></td><td><code>4</code></td><td>Integer</td></tr>
    <tr><td><code>MemoryGB</code></td><td><code>16</code></td><td>Integer</td></tr>
    <tr><td><code>DiskGB</code></td><td><code>100</code></td><td>Expands primary disk if smaller</td></tr>
  </tbody>
</table>

<h3>Optional columns</h3>
<table>
  <thead>
    <tr>
      <th>Column</th>
      <th>Example</th>
      <th>Notes</th>
    </tr>
  </thead>
  <tbody>
    <tr><td><code>DatastoreCluster</code></td><td><code>Prod-DS-Cluster01</code></td><td>Preferred when present</td></tr>
    <tr><td><code>Datastore</code></td><td><code>vsanDatastore</code></td><td>Used only if no <code>DatastoreCluster</code></td></tr>
    <tr><td><code>OSType</code></td><td><code>Windows Server 2019</code> / <code>ubuntu</code></td><td>Mapped to GuestId (or provide a raw GuestId)</td></tr>
    <tr><td><code>PowerOn</code></td><td><code>true</code> / <code>false</code></td><td>Default <code>true</code>; NSX/VDS attach usually needs ON</td></tr>
    <tr><td><code>NsxSegmentId</code></td><td><code>8f5f6b2e-12ab-4cde-9f01-223344556677</code></td><td>Exact NSX segment match (helps when names collide)</td></tr>
  </tbody>
</table>

<p><strong>Guest OS mapping (examples)</strong><br />
<code>Windows Server 2019</code> → <code>windows2019srv_64Guest</code><br />
<code>Windows Server 2022</code> → <code>windows2022srv_64Guest</code><br />
<code>ubuntu</code> / <code>ubuntu 22.04</code> / <code>ubuntu 24.04</code> → <code>ubuntu64Guest</code><br />
<code>rhel8</code> → <code>rhel8_64Guest</code> &middot; <code>rhel9</code> → <code>rhel9_64Guest</code></p>

<hr />

<h2>Example CSV</h2>
<pre><code class="language-csv">Datacenter,ClusterName,Folder,VMName,Template,Network,NsxSegmentId,DatastoreCluster,Datastore,PowerOn,vCPU,MemoryGB,DiskGB,OSType
brm-m01-datacenter,brm-m01-cluster-001,Prod/App,SPVM01,WIN2019-TPL,NSXALB,8f5f6b2e-12ab-4cde-9f01-223344556677,Prod-DS-Cluster01,,true,4,16,100,Windows Server 2019
brm-m01-datacenter,brm-m01-cluster-001,Prod/App,UBU01,UBUNTU-GOLD,VM Network,,Prod-DS-Cluster01,,false,2,8,60,ubuntu
</code></pre>

<hr />

<h2>Usage</h2>

<p><strong>Dry run</strong> (no changes), with verbose logging:</p>
<pre><code class="language-powershell">.\Create-VMs-v0dot5.ps1 `
  -VCenter vc.example.local `
  -CsvPath .\vms.csv `
  -WhatIf -Verbose
</code></pre>

<p><strong>Execute</strong>:</p>
<pre><code class="language-powershell">.\Create-VMs-v0dot5.ps1 `
  -VCenter vc.example.local `
  -CsvPath .\vms.csv `
  -Verbose
</code></pre>

<hr />

<h2>How It Works (Flow)</h2>
<ol>
  <li>Connect to vCenter; import CSV</li>
  <li>Skip rows where <code>VMName</code> already exists</li>
  <li>Resolve <strong>Datacenter → Cluster → Resources pool</strong></li>
  <li>Resolve <strong>DatastoreCluster</strong> (preferred) or <strong>Datastore</strong></li>
  <li>Clone <strong>from Template</strong> with minimal params (<code>-ResourcePool</code> + storage)</li>
  <li>Create <strong>Folder</strong> path and move VM (<code>-InventoryLocation</code>)</li>
  <li>Set <strong>CPU/RAM</strong>, <strong>expand disk</strong>, <strong>set Guest OS type</strong> — all <em>while powered off</em></li>
  <li><strong>Networking</strong>
    <ul>
      <li>VSS/name → set pre-power-on (<code>-NetworkName</code>)</li>
      <li>VDS/NSX → set post-power-on (<code>-Portgroup</code>)</li>
    </ul>
  </li>
  <li><strong>Power on</strong> if <code>PowerOn=true</code></li>
  <li>Output a summary table</li>
</ol>

<hr />

<h2>Troubleshooting</h2>
<p><strong>“Parameter set cannot be resolved…”</strong><br />
This script avoids common clashes by using a minimal <code>New-VM</code> parameter set, splitting NIC change &amp; connection flags, and choosing <code>-Portgroup</code> (VDS/NSX) vs <code>-NetworkName</code> (VSS) correctly. If you still see it, check which cmdlet is named in the error (often a NIC call on unusual dvPortgroup backings).</p>

<p><strong>“The VM must be PoweredOn” when wiring network</strong><br />
Expected for many <strong>NSX/VDS</strong> portgroups. Use <code>PowerOn=true</code>. (If you must keep VMs off but still wire NSX, create a variant that temporarily powers on to attach, then powers off.)</p>

<p><strong>“Set-VM -GuestId … current state (Powered on)”</strong><br />
Fixed here — GuestId is set pre-power-on. If it still appears, verify no external automation powers the VM on earlier.</p>

<p><strong>Not found / ambiguous</strong><br />
Ensure names are exact and unique per DC. The script scopes datastore &amp; datastore cluster lookups to the target DC.</p>

<p><strong>Permissions</strong><br />
Try a manual clone in the UI with the same account to validate privileges if you hit permission errors.</p>

<hr />

<h2>Example Output</h2>
<pre><code>VMName Action  Datacenter           Cluster               Folder    Network   CPU MemoryGB DiskGB Template      DatastoreCluster    Notes
------ ------  -------------------- --------------------- --------- --------- --- -------- ------ ------------- ------------------- -------------------------------
SPVM01 Created brm-m01-datacenter  brm-m01-cluster-001   Prod/App  NSXALB    4   16       100    WIN2019-TPL   Prod-DS-Cluster01   NSX segment connected post-power-on
UBU01  Created brm-m01-datacenter  brm-m01-cluster-001   Prod/App  VM Network 2  8        60     UBUNTU-GOLD   Prod-DS-Cluster01
</code></pre>

<hr />

<h2>Notes &amp; Variants</h2>
<ul>
  <li>Need <em>temporary power-on for NSX wiring</em> while ending powered off? Add a variant that powers on solely to attach the NSX segment, then powers off.</li>
  <li>Multi-NIC support, customization specs, SDRS rules, tagging, etc., can be added while keeping the CSV tidy.</li>
</ul>

<hr />
