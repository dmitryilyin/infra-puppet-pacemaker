require File.join File.dirname(__FILE__), '../../pacemaker/noop'

Puppet::Type.type(:pcmk_resource).provide(:noop, :parent => Puppet::Provider::Noop) do
  # disable this provider
  confine({ :true => false })
end
