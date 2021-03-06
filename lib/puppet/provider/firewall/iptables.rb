require 'puppet/provider/firewall'
require 'digest/md5'

Puppet::Type.type(:firewall).provide :iptables, :parent => Puppet::Provider::Firewall do
  include Puppet::Util::Firewall

  @doc = "Iptables type provider"

  has_feature :iptables
  has_feature :rate_limiting
  has_feature :snat
  has_feature :dnat
  has_feature :interface_match
  has_feature :icmp_match
  has_feature :owner
  has_feature :state_match
  has_feature :reject_type
  has_feature :log_level
  has_feature :log_prefix
  has_feature :mark
  has_feature :tcp_flags
  has_feature :pkttype

  commands :iptables => '/sbin/iptables'
  commands :iptables_save => '/sbin/iptables-save'

  defaultfor :kernel => :linux

  iptables_version = Facter.fact('iptables_version').value
  if (iptables_version and Puppet::Util::Package.versioncmp(iptables_version, '1.4.1') < 0)
    mark_flag = '--set-mark'
  else
    mark_flag = '--set-xmark'
  end

  @resource_map = {
    :burst => '--limit-burst',
    :destination => '-d',
    :dport => '--dports',
    :gid => '--gid-owner',
    :icmp => '--icmp-type',
    :iniface => '-i',
    :jump => '-j',
    :limit => '--limit',
    :log_level => '--log-level',
    :log_prefix => '--log-prefix',
    :name => '--comment',
    :outiface => '-o',
    :port => '--ports',
    :proto => '-p',
    :reject => '--reject-with',
    :set_mark => mark_flag,
    :source => '-s',
    :sport => '--sports',
    :state => '--state',
    :table => '-t',
    :tcp_flags => '--tcp-flags',
    :todest => '--to-destination',
    :toports => '--to-ports',
    :tosource => '--to-source',
    :uid => '--uid-owner',
    :pkttype => '--pkt-type'
  }

  @args_modules = {
    '--icmp-type'      => '-m icmp',
    '--limit'          => '-m limit',
    '--limit-burst'    => '-m limit',
    '--comment'        => '-m comment',
    '--ports'          => '-m multiport',
    '--sports'         => '-m multiport',
    '--dports'         => '-m multiport',
    '--state'          => '-m state',
    '--tcp-flags'      => '-m tcp',
    '--uid-owner'      => '-m owner',
    '--gid-owner'      => '-m owner',
    '--pkt-type'       => '-m pkttype',
    '--reject-with'    => '-j REJECT',
    '--log-level'      => '-j LOG',
    '--log-prefix'     => '-j LOG',
    '--to-destination' => '-j DNAT',
    '--to-source'      => '-j SNAT',
    '--set-mark'       => '-j CONNMARK',
    '--set-xmark'      => '-j CONNMARK',
  }

  @args_aliases = {
      '--port'         => :port,
      '-s'             => :source,
      '--sport'        => :sport,
      '-d'             => :destination,
      '--dport'        => :dport,
      '--to-port'      => :toports,
  }

  # Invert hash and include aliases for arg to param lookups.
  @args_map = @resource_map.invert
  @args_map.merge!(@args_aliases)

  def insert
    debug 'Inserting rule %s' % resource[:name]
    iptables insert_args
  end

  def update
    debug 'Updating rule %s' % resource[:name]
    iptables update_args
  end

  def delete
    debug 'Deleting rule %s' % resource[:name]
    iptables delete_args
  end

  def exists?
    properties[:ensure] != :absent
  end

  # Flush the property hash once done.
  def flush
    debug("[flush]")
    if @property_hash.delete(:needs_change)
      notice("Properties changed - updating rule")
      update
    end
    @property_hash.clear
  end

  def self.instances
    debug "[instances]"
    table = nil
    rules = []
    counter = 1

    # String#lines would be nice, but we need to support Ruby 1.8.5
    iptables_save.split("\n").each do |line|
      unless line =~ /^\#\s+|^\:\S+|^COMMIT|^FATAL/
        if line =~ /^\*/
          table = line.sub(/\*/, "")
        else
          if hash = rule_to_hash(line, table, counter)
            rules << new(hash)
            counter += 1
          end
        end
      end
    end
    rules
  end

  def self.rule_to_hash(line, table, counter)
    hash = {}
    keys = []
    row = []
    values = line.dup

    row = values.split(%r{\s+})
    i = 0
    invertnext = false

    hash[:modules] = []
    hash[:invert] = {}

    while i < row.length
      case row[i]
      when /-A/
        hash[:chain] = row[i+1]
      when /-m/
        hash[:modules] << row[i+1]
      when /--log-prefix/
        name = []
        i += 1
        if (row[i] =~ /^"/ and not row[i] =~ /^".*"$/ )
            while not row[i] =~ /"$/
                name << row[i]
                i += 1
            end
            name = name.join(' ')
        else
            name = row[i]
        end
        name = name.gsub(/"/, '')
        hash[:log_prefix] = name
      when /--comment/
        name = []
        while not row[i] =~ /"$/
          i += 1
          name << row[i]
        end
        name = name.join(' ')
        name = name.gsub(/"/, '')
        hash[:name] = name
      when /--tcp-flags/
        hash[:tcp_flags] = row[i+1] + " " + row[i+2]
        i += 1
      when /!/
        # TODO handle inverse matches
        invertnext = true
      else
        if @args_map[row[i]]
          hash[ @args_map[row[i]] ] = row[i+1]
          if invertnext
            hash[:invert][ @args_map[row[i]] ] = true
            invertnext = false
          end
        end
      end
      i += 1
    end

    [:source, :destination].each do |prop|
      hash[prop] = Puppet::Util::IPCidr.new(hash[prop]).cidr unless hash[prop].nil?
    end

    [:dport, :sport, :port, :state].each do |prop|
      hash[prop] = hash[prop].split(',') if ! hash[prop].nil?
    end

    # Our type prefers hyphens over colons for ranges so ...
    # Iterate across all ports replacing colons with hyphens so that ranges match
    # the types expectations.
    [:dport, :sport, :port].each do |prop|
      next unless hash[prop]
      hash[prop] = hash[prop].collect do |elem|
        elem.gsub(/:/,'-')
      end
    end

    # States should always be sorted. This ensures that the output from
    # iptables-save and user supplied resources is consistent.
    hash[:state] = hash[:state].sort unless hash[:state].nil?

    # This forces all existing, commentless rules to be moved to the bottom of the stack.
    # Puppet-firewall requires that all rules have comments (resource names) and will fail if
    # a rule in iptables does not have a comment. We get around this by appending a high level
    if ! hash[:name]
      hash[:name] = "9999 #{Digest::MD5.hexdigest(line)}"
    end

    # Iptables defaults to log_level '4', so it is omitted from the output of iptables-save.
    # If the :jump value is LOG and you don't have a log-level set, we assume it to be '4'.
    if hash[:jump] == 'LOG' && ! hash[:log_level]
      hash[:log_level] = '4'
    end

    hash[:line] = line
    hash[:provider] = self.name.to_s
    hash[:table] = table
    hash[:ensure] = :present

    # Munge some vars here ...

    # Proto should equal 'all' if undefined
    hash[:proto] = "all" if !hash.include?(:proto)

    # If the jump parameter is set to one of: ACCEPT, REJECT or DROP then
    # we should set the action parameter instead.
    if ['ACCEPT','REJECT','DROP'].include?(hash[:jump]) then
      hash[:action] = hash[:jump].downcase
      hash.delete(:jump)
    end

    hash
  end

  def insert_args
    args = []
    args << ["-I", resource[:chain], insert_order]
    args << general_args
    args
  end

  def update_args
    args = []
    args << ["-R", resource[:chain], insert_order]
    args << general_args
    args
  end

  def delete_args
    count = []
    line = properties[:line].gsub(/\-A/, '-D').split

    # Grab all comment indices
    line.each do |v|
      if v =~ /"/
        count << line.index(v)
      end
    end

    if ! count.empty?
      # Remove quotes and set first comment index to full string
      line[count.first] = line[count.first..count.last].join(' ').gsub(/"/, '')

      # Make all remaining comment indices nil
      ((count.first + 1)..count.last).each do |i|
        line[i] = nil
      end
    end

    line.unshift("-t", properties[:table])

    # Return array without nils
    line.compact
  end

  def general_args
    debug "Current resource: %s" % resource.class

    args = []
    already_called = Hash.new
    resource_map = self.class.instance_variable_get('@resource_map')
    args_modules = self.class.instance_variable_get('@args_modules')

    resource_map.each_key do |res|
      resource_value = nil
      if (resource[res]) then
        resource_value = resource[res]
      elsif res == :jump and resource[:action] then
        # In this case, we are substituting jump for action
        resource_value = resource[:action].to_s.upcase
      else
        next
      end

      # Lookup arguments and any required modules.
      resource_args = resource_map[res].split(' ')
      resource_module = args_modules[resource_args[0]]
      if resource_module and not already_called[resource_module] then
        debug "Adding module: #{resource_module}"
        args << resource_module.split(' ')
        already_called[resource_module] = 1
      end

      # Protocol and jump needs to go to the front (because they can load
      # modules).
      if (resource_args[0] =~ /^-[jp]$/) then
        both = "#{resource_args} #{resource_value}"
        if (not already_called[both]) then
          debug "Unshifting: '#{both}"
          args.unshift(resource_args, resource_value)
          already_called[both] = 1
        else
          debug "Not unshifting #{both} because it was already called"
        end
        next
      else
        debug "Pushing: '#{resource_args}' (and later, #{resource_value}))}"
        args << resource_args
      end

      # For sport and dport, convert hyphens to colons since the type
      # expects hyphens for ranges of ports.
      if [:sport, :dport, :port].include?(res) then
        resource_value = resource_value.collect do |elem|
          elem.gsub(/-/, ':')
        end
      end

      # our tcp_flags takes a single string with comma lists separated
      # by space
      # --tcp-flags expects two arguments
      if res == :tcp_flags
        one, two = resource_value.split(' ')
        args << one
        args << two
      elsif resource_value.is_a?(Array)
        args << resource_value.join(',')
      else
        args << resource_value
      end
    end

    args
  end

  def insert_order
    debug("[insert_order]")
    rules = []

    # Find list of current rules based on chain and table
    self.class.instances.each do |rule|
      if rule.chain == resource[:chain].to_s and rule.table == resource[:table].to_s
        rules << rule.name
      end
    end

    # No rules at all? Just bail now.
    return 1 if rules.empty?

    my_rule = resource[:name].to_s
    rules << my_rule
    rules.sort.index(my_rule) + 1
  end
end
