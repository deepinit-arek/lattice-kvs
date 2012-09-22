require './test_common'
require 'kvs/kvs'

class TestMergeMapKvs < MiniTest::Unit::TestCase
  include LatticeTestSugar

  def test_merge_simple
    r = KvsReplica.new
    r.run_bg
    c = KvsClient.new(r.ip_port, Bud::MaxLattice)
    c.run_bg

    c.write('foo', max(5))
    res = c.read('foo')
    assert_equal(5, res.reveal)

    c.write('foo', max(3))
    res = c.read('foo')
    assert_equal(5, res.reveal)

    c.write('foo', max(7))
    res = c.read('foo')
    assert_equal(7, res.reveal)

    c.stop_bg
    r.stop_bg
  end

  def bump_vc(vc, node_id)
    tmp = vc.merge(map(node_id => max(0)))
    tmp.merge(map(node_id => tmp.at(node_id) + 1))
  end

  def test_vc_simple
    r = KvsReplica.new
    r.run_bg
    c = KvsClient.new(r.ip_port, PairLattice)
    c.run_bg
    c2 = KvsClient.new(r.ip_port, PairLattice)
    c2.run_bg

    new_vc = bump_vc(map, c.ip_port)
    c.write('foo', pair(new_vc, set(5)))
    res = c.read('foo')
    assert_equal({c.ip_port => 1}, unwrap_map(res.fst.reveal))
    assert_equal([5].to_set, res.snd.reveal)

    new_vc = bump_vc(map, c2.ip_port)
    c2.write('foo', pair(new_vc, set(3)))
    c2_res = c2.read('foo')
    assert_equal({c.ip_port => 1, c2.ip_port => 1},
                 unwrap_map(c2_res.fst.reveal))
    assert_equal([3,5].to_set, c2_res.snd.reveal)

    new_vc = bump_vc(res.fst, c.ip_port)
    c.write('foo', pair(new_vc, set(7)))
    res = c.read('foo')
    assert_equal({c.ip_port => 2, c2.ip_port => 1},
                 unwrap_map(res.fst.reveal))
    assert_equal([3,5,7].to_set, res.snd.reveal)

    new_vc = bump_vc(res.fst, c.ip_port)
    c.write('foo', pair(new_vc, set(9)))
    res = c.read('foo')
    assert_equal({c.ip_port => 3, c2.ip_port => 1},
                 unwrap_map(res.fst.reveal))
    assert_equal([9].to_set, res.snd.reveal)

    [c, c2, r].each {|n| n.stop_bg}
  end

  def test_repl
    nodes = Array.new(3) { ReplicatedKvsReplica.new }
    nodes.each {|n| n.run_bg}
    clients = nodes.map {|n| KvsClient.new(n.ip_port, PairLattice)}
    clients.each {|c| c.run_bg}

    c0, c1, c2 = clients
    new_vc = bump_vc(map, c0.ip_port)
    c0.write('foo', pair(new_vc, set(4)))
    res = c0.read('foo')
    assert_equal({c0.ip_port => 1}, unwrap_map(res.fst.reveal))
    assert_equal([4].to_set, res.snd.reveal)

    c0.cause_repl(nodes[1])
    res = c1.read('foo')
    assert_equal({c0.ip_port => 1}, unwrap_map(res.fst.reveal))
    assert_equal([4].to_set, res.snd.reveal)

    new_vc = bump_vc(res.fst, c1.ip_port)
    c1.write('foo', pair(new_vc, set(12)))
    res = c1.read('foo')
    assert_equal({c0.ip_port => 1, c1.ip_port => 1},
                 unwrap_map(res.fst.reveal))
    assert_equal([12].to_set, res.snd.reveal)

    new_vc = bump_vc(map, c2.ip_port)
    c2.write('foo', pair(new_vc, set(13)))
    res = c2.read('foo')
    assert_equal({c2.ip_port => 1}, unwrap_map(res.fst.reveal))
    assert_equal([13].to_set, res.snd.reveal)

    c1.cause_repl(nodes[2])
    res = c2.read('foo')
    assert_equal({c0.ip_port => 1, c1.ip_port => 1, c2.ip_port => 1},
                 unwrap_map(res.fst.reveal))
    assert_equal([12,13].to_set, res.snd.reveal)

    c2.cause_repl(nodes[1])
    res = c1.read('foo')
    assert_equal({c0.ip_port => 1, c1.ip_port => 1, c2.ip_port => 1},
                 unwrap_map(res.fst.reveal))
    assert_equal([12,13].to_set, res.snd.reveal)

    c1.cause_repl(nodes[0])
    res = c0.read('foo')
    assert_equal({c0.ip_port => 1, c1.ip_port => 1, c2.ip_port => 1},
                 unwrap_map(res.fst.reveal))
    assert_equal([12,13].to_set, res.snd.reveal)

    (nodes + clients).each {|n| n.stop_bg}
  end
end

class TestQuorumKvs < MiniTest::Unit::TestCase
  include LatticeTestSugar

  def test_singleton_quorum
    r = KvsReplica.new
    r.run_bg
    q = QuorumKvsClient.new([r.ip_port], [r.ip_port], Bud::MaxLattice)
    q.run_bg

    q.write('bar', max(3))
    res = q.read('bar')
    assert_equal(max(3), res)

    r.stop_bg
    q.stop_bg
  end

  def test_quorum_write_all
    nodes = Array.new(3) { KvsReplica.new }
    nodes.each {|n| n.run_bg }
    addr_list = nodes.map {|n| n.ip_port}
    q = QuorumKvsClient.new(addr_list, addr_list, Bud::MaxLattice)
    q.run_bg

    q.write('bar', max(7))
    nodes.each do |n|
      c_for_n = KvsClient.new(n.ip_port, Bud::MaxLattice)
      c_for_n.run_bg
      res = c_for_n.read('bar')
      assert_equal(max(7), res)
      c_for_n.stop
    end

    (nodes + [q]).each {|n| n.stop}
  end

  def test_quorum_write_one_read_all
    nodes = Array.new(5) { KvsReplica.new }
    nodes.each {|n| n.run_bg }
    addr_list = nodes.map {|n| n.ip_port}
    q = QuorumKvsClient.new([addr_list.last], addr_list, Bud::SetLattice)
    q.run_bg

    q.write('baz', set(2))
    res = q.read('baz')
    assert_equal(set(2), res)

    (nodes + [q]).each {|n| n.stop}
  end
end