require_relative '../pcmk_xml'

Puppet::Type.type(:service).provide(:pacemaker, :parent => Puppet::Provider::PcmkXML) do

  has_feature :enableable
  has_feature :refreshable

  commands :crm_node => 'crm_node'
  commands :crm_resource => 'crm_resource'
  commands :crm_attribute => 'crm_attribute'
  commands :cibadmin => 'cibadmin'

  # original title of the service
  # @return [String]
  def service_title
    @resource.title
  end

  # original name of the service
  # in most cases will be equal to the title
  # but can be different
  # @return [String]
  def service_name
    resource[:name]
  end

  # check if the service name is the same as service title
  # @return [true,false]
  def name_equals_title?
    service_title == service_name
  end

  # find a primitive name that is present in the CIB
  # or nil if none is present
  # @return [String,nil]
  def pick_existing_name(*names)
    names.flatten.find do |name|
      primitive_exists? name
    end
  end

  # generate a list of strings the service name could be written as
  # perhaps, one of them could be found in the CIB
  # @param name [String]
  # @return [Array<String>]
  def service_name_variations(name)
    name = name.to_s
    variations = []
    variations << name
    if name.start_with? 'p_'
      variations << name.gsub(/^p_/, '')
    else
      variations << "p_#{name}"
    end

    simple_name = name.gsub(/^(ms-)|(clone-)/, '')
    unless simple_name == name
      variations << simple_name
      if simple_name.start_with? 'p_'
        variations << simple_name.gsub(/^p_/, '')
      else
        variations << "p_#{simple_name}"
      end
    end
    variations
  end

  # get the correct name of the service primitive
  # @return [String]
  def name
    return @name if @name
    @name = pick_existing_name service_name_variations(service_title), service_name_variations(service_name)
    if @name
      message = "Using CIB name '#{@name}' for primitive '#{service_title}'"
      message += " with name '#{service_name}'" unless name_equals_title?
      debug message
    else
      message = "Primitive '#{service_title}'"
      message += " with name '#{service_name}'" unless name_equals_title?
      message += ' was not found in CIB!'
      fail message
    end
    @name
  end

  # full name of the primitive
  # if resource is complex use group name
  # @return [String]
  def full_name
    return @full_name if @full_name
    if primitive_is_complex? name
      full_name = primitives[name]['name']
      debug "Using full name '#{full_name}' for complex primitive '#{name}'"
      @full_name = full_name
    else
      @full_name = name
    end
  end

  # name of the basic service without 'p_' prefix
  # used to disable the basic service.
  # Uses "name" property if it's not the same as title
  # because most likely it will be the real system service name
  # @return [String]
  def basic_service_name
    return @basic_service_name if @basic_service_name
    basic_service_name = name
    basic_service_name = service_name unless name_equals_title?
    if basic_service_name.start_with? 'p_'
      basic_service_name = basic_service_name.gsub(/^p_/, '')
    end
    debug "Using '#{basic_service_name}' as the basic service name for the primitive '#{name}'"
    @basic_service_name = basic_service_name
  end

  # cleanup a primitive and
  # wait until cleanup finishes
  def cleanup
    cleanup_primitive full_name, hostname
    wait_for_status name
  end

  # run the disable basic service action only
  # if it's enabled fot this provider action
  # and is globally enabled too
  # @param [Symbol] action (:start/:stop/:status)
  def disable_basic_service_on_action(action)
    if action == :start
      return unless pacemaker_options[:disable_basic_service_on_start]
    elsif action == :stop
      return unless pacemaker_options[:disable_basic_service_on_stop]
    elsif action == :status
      return unless pacemaker_options[:disable_basic_service_on_status]
    else
      fail "Action '#{action}' is incorrect!"
    end

    disable_basic_service
  end

  # called by Puppet to determine if the service
  # is running on the local node
  # @return [:running,:stopped]
  def status
    debug "Call: 'status' for Pacemaker service '#{name}' on node '#{hostname}'"
    disable_basic_service_on_action :status

    cib_reset 'service_status'
    wait_for_online 'service_status'

    if primitive_is_multistate? name
      out = service_status_mode pacemaker_options[:status_mode_multistate]
    elsif primitive_is_clone? name
      out = service_status_mode pacemaker_options[:status_mode_clone]
    else
      out = service_status_mode pacemaker_options[:status_mode_simple]
    end

    if pacemaker_options[:add_location_constraint]
      if out == :running and not service_location_exists? full_name, hostname
        debug 'Location constraint is missing. Service status set to "stopped".'
        out = :stopped
      end
    end

    if pacemaker_options[:cleanup_on_status]
      if out == :running and primitive_has_failures? name, hostname
        debug "Primitive: '#{name}' has failures on the node: '#{hostname}' Service status set to 'stopped'."
        out = :stopped
      end
    end

    debug "Return: '#{out}' (#{out.class})"
    debug cluster_debug_report "#{@resource} status"
    out
  end

  # called by Puppet to start the service
  def start
    debug "Call 'start' for Pacemaker service '#{name}' on node '#{hostname}'"
    disable_basic_service_on_action :start

    enable unless primitive_is_managed? name

    if pacemaker_options[:cleanup_on_start]
      if not pacemaker_options[:cleanup_only_if_failures] or primitive_has_failures? name, hostname
        cleanup
      end
    end

    if pacemaker_options[:add_location_constraint]
      service_location_add full_name, hostname unless service_location_exists? full_name, hostname
    end

    if primitive_is_multistate? name
      service_start_mode pacemaker_options[:start_mode_multistate]
    elsif primitive_is_clone? name
      service_start_mode pacemaker_options[:start_mode_clone]
    else
      service_start_mode pacemaker_options[:start_mode_simple]
    end

    debug cluster_debug_report "#{@resource} start"
  end

  # called by Puppet to stop the service
  def stop
    debug "Call 'stop' for Pacemaker service '#{name}' on node '#{hostname}'"
    disable_basic_service_on_action :stop

    enable unless primitive_is_managed? name

    if pacemaker_options[:cleanup_on_stop]
      if not pacemaker_options[:cleanup_only_if_failures] or primitive_has_failures? name, hostname
        cleanup
      end
    end

    if primitive_is_multistate? name
      service_stop_mode pacemaker_options[:stop_mode_multistate]
    elsif primitive_is_clone? name
      service_stop_mode pacemaker_options[:stop_mode_clone]
    else
      service_stop_mode pacemaker_options[:stop_mode_simple]
    end
    debug cluster_debug_report "#{@resource} stop"
  end

  # called by Puppet to restart the service
  def restart
    debug "Call 'restart' for Pacemaker service '#{name}' on node '#{hostname}'"
    if pacemaker_options[:restart_only_if_local] and not primitive_is_running? name, hostname
      info "Pacemaker service '#{name}' is not running on node '#{hostname}'. Skipping restart!"
      return
    end

    begin
      stop
    rescue
      debug 'The service have failed to stop! Trying to start it anyway...'
    ensure
      start
    end
  end

  # wait for the service to start using
  # the selected method.
  # @param mode [:global, :master, :local]
  def service_start_mode(mode = :global)
    start_action = Proc.new do
      unban_primitive name, hostname
      start_primitive name
      start_primitive full_name
    end

    if mode == :master
      debug "Choose master start for Pacemaker service '#{name}'"
      start_action.call
      wait_for_master(name) do
        start_action.call
      end
    elsif mode == :local
      debug "Choose local start for Pacemaker service '#{name}' on node '#{hostname}'"
      start_action.call
      wait_for_start(name, hostname) do
        start_action.call
      end
    elsif :global
      debug "Choose global start for Pacemaker service '#{name}'"
      start_action.call
      wait_for_start(name) do
        start_action.call
      end
    else
      fail "Unknown service start mode '#{mode}'"
    end
  end

  # wait for the service to stop using
  # the selected method.
  # @param mode [:global, :master, :local]
  def service_stop_mode(mode = :global)
    if mode == :master
      debug "Choose master stop for Pacemaker service '#{name}'"
      ban_primitive name, hostname
      wait_for_stop(name, hostname) do
        ban_primitive name, hostname
      end
    elsif mode == :local
      debug "Choose local stop for Pacemaker service '#{name}' on node '#{hostname}'"
      ban_primitive name, hostname
      wait_for_stop(name, hostname) do
        ban_primitive name, hostname
      end
    elsif mode == :global
      debug "Choose global stop for Pacemaker service '#{name}'"
      stop_primitive name
      wait_for_stop(name) do
        stop_primitive name
      end
    else
      fail "Unknown service stop mode '#{mode}'"
    end
  end

  # determine the status of the service using
  # the selected method.
  # @param mode [:global, :master, :local]
  # @return [:running,:stopped]
  def service_status_mode(mode = :local)
    if mode == :local
      debug "Choose local status for Pacemaker service '#{name}' on node '#{hostname}'"
      get_primitive_puppet_status name, hostname
    elsif mode == :global
      debug "Choose global status for Pacemaker service '#{name}'"
      get_primitive_puppet_status name
    else
      fail "Unknown service status mode '#{mode}'"
    end
  end

  # called by Puppet to enable the service
  def enable
    debug "Call 'enable' for Pacemaker service '#{name}' on node '#{hostname}'"
    manage_primitive name
  end

  # called by Puppet to disable  the service
  def disable
    debug "Call 'disable' for Pacemaker service '#{name}' on node '#{hostname}'"
    unmanage_primitive name
  end

  alias :manual_start :disable

  # called by Puppet to determine if the service is enabled
  # @return [:true,:false]
  def enabled?
    debug "Call 'enabled?' for Pacemaker service '#{name}' on node '#{hostname}'"
    out = get_primitive_puppet_enable name
    debug "Return: '#{out}' (#{out.class})"
    out
  end

  # check if this service provider class is enabled
  # and can be used
  # @param [Class] provider_class
  # @return [true,false]
  def service_provider_enabled?(provider_class)
    return false if self.is_a? provider_class
    return true unless pacemaker_options[:disabled_basic_service_providers].is_a? Array
    return true unless pacemaker_options[:disabled_basic_service_providers].any?
    not pacemaker_options[:disabled_basic_service_providers].include? provider_class.name.to_s
  end

  # get a list of the provider names which could be used on the
  # current system to manage the basic service.
  # @return [Array<Symbol>]
  def suitable_providers
    return @suitable_providers if @suitable_providers
    @suitable_providers = []
    [
        @resource.class.defaultprovider,
        @resource.class.suitableprovider,
    ].flatten.uniq.each do |provider_class|
      if service_provider_enabled? provider_class
        @suitable_providers << provider_class.name
      end
    end
    @suitable_providers
  end

  attr_writer :suitable_providers

  # Get the parameters hash from the resource object
  # which can be used to create additional instances with
  # the same parameters.
  # @return [Hash<Symbol => Object>]
  def parameters_hash(provider_class_name=nil)
    parameters_hash = {}
    @resource.parameters_with_value.each do |parameter|
      parameters_hash.store parameter.name, parameter.value
    end
    parameters_hash.store :name, basic_service_name
    parameters_hash.store :provider, provider_class_name if provider_class_name
    parameters_hash
  end

  # @return [Array<Puppet::Type::Service::Provider>]
  def extra_providers
    return @extra_providers if @extra_providers
    @extra_providers = []
    suitable_providers.each do |provider_class_name|
      begin
        type = @resource.class.new parameters_hash provider_class_name
        @extra_providers << type.provider
      rescue => e
        info "Could not get an extra provider for the Pacemaker primitive '#{name}': #{e.message}"
        next
      end
    end
    @extra_providers
  end

  # check if this provider is native service based and the basic
  # service should not be disabled
  # @return [true,false]
  def native_based_primitive?
    return false unless pacemaker_options[:native_based_primitive_classes].is_a? Array
    return false unless pacemaker_options[:native_based_primitive_classes].any?
    pacemaker_options[:native_based_primitive_classes].include? primitive_class name
  end

  # disable and stop the basic service
  # using all suitable providers
  def disable_basic_service
    # skip native-based primitive classes
    if native_based_primitive?
      info "Not stopping basic service '#{basic_service_name}', since its Pacemaker primitive is using primitive_class '#{primitive_class name}'"
      return
    end

    return unless extra_providers.is_a? Array and extra_providers.any?
    extra_providers.each do |extra_provider|
      begin
        if extra_provider.enableable? and extra_provider.enabled? == :true
          info "Disable basic service '#{extra_provider.name}' using provider '#{extra_provider.class.name}'"
          extra_provider.disable
        else
          info "Basic service '#{extra_provider.name}' is disabled as reported by '#{extra_provider.class.name}' provider"
        end
        if extra_provider.status == :running
          info "Stop basic service '#{extra_provider.name}' using provider '#{extra_provider.class.name}'"
          extra_provider.stop
        else
          info "Basic service '#{extra_provider.name}' is stopped as reported by '#{extra_provider.class.name}' provider"
        end
      rescue => e
        info "Could not disable basic service for Pacemaker primitive '#{name}' using '#{extra_provider.class.name}' provider: #{e.message}"
        next
      end
    end
  end

end
