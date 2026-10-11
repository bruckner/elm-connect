//! Strongly-connected components of a directed graph over `0..n`, for
//! recursive messages and package import cycles.

/// The strongly-connected components of the graph with nodes `0..n` and
/// the given adjacency lists, by Tarjan's algorithm. Each component lists
/// its nodes in ascending order; components come in reverse topological
/// order of the condensed graph. Iterative, so deep graphs cannot overflow
/// the stack.
pub(crate) fn strongly_connected(edges: &[Vec<usize>]) -> Vec<Vec<usize>> {
    let n = edges.len();
    let mut index = vec![usize::MAX; n];
    let mut low = vec![0; n];
    let mut on_stack = vec![false; n];
    let mut stack = Vec::new();
    let mut components = Vec::new();
    let mut next = 0;

    for root in 0..n {
        if index[root] != usize::MAX {
            continue;
        }
        // Each frame: a node and how many of its edges are explored.
        let mut work = vec![(root, 0)];
        index[root] = next;
        low[root] = next;
        next += 1;
        stack.push(root);
        on_stack[root] = true;

        while let Some(&mut (node, ref mut explored)) = work.last_mut() {
            if let Some(&target) = edges[node].get(*explored) {
                *explored += 1;
                if index[target] == usize::MAX {
                    index[target] = next;
                    low[target] = next;
                    next += 1;
                    stack.push(target);
                    on_stack[target] = true;
                    work.push((target, 0));
                } else if on_stack[target] {
                    low[node] = low[node].min(index[target]);
                }
                continue;
            }
            work.pop();
            if let Some(&(parent, _)) = work.last() {
                low[parent] = low[parent].min(low[node]);
            }
            if low[node] == index[node] {
                let mut component = Vec::new();
                while let Some(member) = stack.pop() {
                    on_stack[member] = false;
                    component.push(member);
                    if member == node {
                        break;
                    }
                }
                component.sort_unstable();
                components.push(component);
            }
        }
    }
    components
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sorted(mut components: Vec<Vec<usize>>) -> Vec<Vec<usize>> {
        components.sort();
        components
    }

    #[test]
    fn finds_cycles_and_singletons() {
        // 0 -> 1 -> 2 -> 0, 3 -> 3, 4 -> 0
        let edges = vec![vec![1], vec![2], vec![0], vec![3], vec![0]];
        assert_eq!(
            sorted(strongly_connected(&edges)),
            vec![vec![0, 1, 2], vec![3], vec![4]]
        );
    }

    #[test]
    fn handles_a_long_chain() {
        let n = 100_000;
        let edges: Vec<Vec<usize>> = (0..n).map(|i| vec![(i + 1) % n]).collect();
        assert_eq!(strongly_connected(&edges).len(), 1);
    }
}
