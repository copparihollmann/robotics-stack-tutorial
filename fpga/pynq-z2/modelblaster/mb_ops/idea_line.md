### One more output rule: say what this version tries

Right before the function definition, the ```c block must have exactly one comment line of the form

    // idea: <what this version does differently, in under 70 characters>

for example `// idea: unroll the inner loop by 4 and hoist the bounds checks`. It is shown to the
people watching the optimization. It does not change what the code must do.
