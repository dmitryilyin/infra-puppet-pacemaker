require 'rubygems'
require 'puppet'
require 'pry'

base = File.expand_path File.join File.dirname(__FILE__), '..', 'pacemaker'
require File.join base, 'provider'

# This console can be used to debug the pacemaker library
# and its methods or for manual control over the cluster.
#
# It requires 'pry' gem to be installed.
#
# You can give it a dumped cib XML file for the first argument
# id you want to debug the code without Pacemaker running.

class Puppet::Provider::Pacemaker
  [:cibadmin, :crm_attribute, :crm_node, :crm_resource, :crm_attribute].each do |tool|
    define_method(tool) do |*args|
      command = [tool.to_s] + args
      if Puppet::Util::Execution.respond_to? :execute
        Puppet::Util::Execution.execute command
      else
        Puppet::Util.execute command
      end
    end
  end
end

class Puppet::Provider::Pacemaker
  # override the debug method
  def debug(msg)
    puts msg
  end
  alias :info :debug
end

common = Puppet::Provider::Pacemaker.new
if $ARGV[0] and File.exists? $ARGV[0]
  xml = File.read $ARGV[0]
  common.cib = xml
end

common.pry

